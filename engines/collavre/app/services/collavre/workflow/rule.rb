# frozen_string_literal: true

module Collavre
  module Workflow
    class Rule < Data.define(:creative_id, :event_name, :conditions, :handler_type, :agent_ids, :emits)
      HANDLER_TYPES = %w[agent human none].freeze
      CONDITION_TYPES = {
        "source" => ->(value) { value.is_a?(Array) && value.all?(String) },
        "author_agent" => ->(value) { value == true || value == false },
        "body_contains" => ->(value) { value.is_a?(Array) && value.all?(String) },
        "liquid" => ->(value) { value.is_a?(String) }
      }.freeze

      def self.parse(creative)
        Parser.new(creative).parse
      rescue StandardError
        [ nil, [ error(:invalid_structure) ] ]
      end

      def self.from(creative)
        rule, errors = parse(creative)
        Rails.logger.warn("[Workflow::Rule] Creative #{creative_id_for_log(creative)}: #{errors.join(', ')}") if errors.any?
        rule
      rescue StandardError => exception
        Rails.logger.warn("[Workflow::Rule] Creative #{creative_id_for_log(creative)}: #{exception.message}")
        nil
      end

      def self.error(key, **options)
        I18n.t("collavre.workflow.rule.errors.#{key}", **options)
      end

      def self.creative_id_for_log(creative)
        creative&.id
      rescue StandardError
        "unknown"
      end
      private_class_method :creative_id_for_log

      def responder?
        handler_type == "agent"
      end

      class Parser
        def initialize(creative)
          @creative = creative
          @errors = []
        end

        def parse
          return invalid unless data.is_a?(Hash)
          return [ nil, [] ] unless data["kind"] == "workflow_rule"
          return invalid unless payload.is_a?(Hash)

          parse_fields
          return [ nil, @errors ] if fatal?

          [ build_rule, @errors ]
        end

        private

        def data
          @data ||= @creative&.data
        end

        def payload
          @payload ||= data["workflow_rule"]
        end

        def parse_fields
          parse_event
          parse_handler
          parse_conditions
          parse_emits
        end

        def parse_event
          @event_name = payload["on"]
          if @event_name.blank?
            add_fatal(:missing_on)
          elsif !SystemEvents::Vocabulary.known?(@event_name)
            add_fatal(:unknown_event, event: @event_name)
          end
        end

        def parse_handler
          handler = payload["handler"]
          return add_fatal(:unknown_handler) unless handler.is_a?(Hash)

          @handler_type = handler["type"]
          return add_fatal(:unknown_handler) unless HANDLER_TYPES.include?(@handler_type)

          @agent_ids = handler.fetch("agent_ids", [])
          return add_fatal(:invalid_structure) unless valid_agent_ids?

          add_fatal(:no_agent) if @handler_type == "agent" && @agent_ids.empty?
        end

        def valid_agent_ids?
          @agent_ids.is_a?(Array) && @agent_ids.all? { |id| id.is_a?(Integer) && id.positive? }
        end

        def parse_conditions
          source = payload.fetch("when", {})
          return add_fatal(:invalid_structure) unless source.is_a?(Hash)

          @conditions = source.each_with_object({}) do |(key, value), known|
            if !Conditions::KEYS.include?(key)
              add_error(:unknown_condition, condition: key)
            elsif !CONDITION_TYPES.fetch(key).call(value)
              add_fatal(:invalid_structure)
            else
              known[key] = immutable_copy(value)
            end
          end.freeze
        end

        def parse_emits
          return @emits = nil unless payload.key?("emits")

          source = payload["emits"]
          return add_fatal(:invalid_structure) unless source.is_a?(String)

          @emits = immutable_copy(source)
          add_error(:unknown_emit, event: source) unless SystemEvents::Vocabulary.known?(source)
        end

        def build_rule
          Rule.new(
            creative_id: @creative.id,
            event_name: immutable_copy(@event_name),
            conditions: @conditions,
            handler_type: immutable_copy(@handler_type),
            agent_ids: immutable_copy(@agent_ids),
            emits: @emits
          )
        end

        def immutable_copy(value)
          case value
          when Array then value.map { |item| immutable_copy(item) }.freeze
          else value.frozen? ? value : value.dup.freeze
          end
        end

        def invalid
          add_fatal(:invalid_structure)
          [ nil, @errors ]
        end

        def add_fatal(key, **options)
          @fatal = true
          add_error(key, **options)
        end

        def add_error(key, **options)
          @errors << Rule.error(key, **options)
        end

        def fatal?
          @fatal == true
        end
      end
      private_constant :Parser, :CONDITION_TYPES
    end
  end
end
