# frozen_string_literal: true

module Collavre
  module CliProxy
    # Per-run options a CLI Proxy agent turn is sent with: the model and the
    # reasoning effort. Effort resolves as message override > agent default >
    # proxy default (nil, meaning the request omits the field).
    #
    # Codex Fast mode is deliberately not here. The proxy takes it from the
    # workspace manifest only, never per request.
    class RunOptions
      MODEL_PREFIX = AdapterEngine::MODEL_PREFIX

      # The values the proxy forwards for each engine. It ignores anything else,
      # so a value is dropped here rather than sent to be silently discarded.
      EFFORTS = {
        "claude" => %w[low medium high xhigh max],
        "codex" => %w[none minimal low medium high xhigh],
        "codex_custom" => %w[none minimal low medium high xhigh]
      }.freeze
      ALL_EFFORTS = EFFORTS.values.flatten.uniq.freeze
      FAST_MODE_ADAPTERS = %w[codex_local].freeze
      MESSAGE_KEYS = %w[reasoning_effort].freeze
      MAX_VALUE_LENGTH = 255

      attr_reader :model, :reasoning_effort

      class << self
        # "paperclip/claude_local/opus" -> "claude_local"; nil outside the
        # namespace.
        def adapter_for(model)
          model = model.to_s.strip
          return nil unless model.start_with?(MODEL_PREFIX)

          model.delete_prefix(MODEL_PREFIX).split("/").first.presence
        end

        def efforts_for(model)
          EFFORTS.fetch(AdapterEngine.for_model(model), [])
        end

        def fast_mode_supported?(model)
          return false unless FAST_MODE_ADAPTERS.include?(adapter_for(model))

          explicit_model = model.to_s.strip.split("/", 3)[2]
          return true if explicit_model.nil?

          version = explicit_model.match(/\Agpt-(\d+)\.(\d+)(?:-.*)?\z/)
          version.present? && ([ version[1].to_i, version[2].to_i ] <=> [ 5, 4 ]) >= 0
        end

        # Strips a submitted comment[agent_run_options] down to the keys this
        # class reads. Returns nil when nothing is left, so an untouched
        # composer leaves no trace on the comment.
        def sanitize_message_options(raw)
          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          return nil unless raw.is_a?(Hash)

          options = raw.stringify_keys.slice(*MESSAGE_KEYS).filter_map do |key, value|
            value = value.to_s.strip
            [ key, value ] if value.present? && value.length <= MAX_VALUE_LENGTH
          end.to_h
          options.presence
        end

        def resolve(agent:, message_options: nil)
          new(agent: agent, message_options: message_options)
        end
      end

      def initialize(agent:, message_options: nil)
        overrides = self.class.sanitize_message_options(message_options) || {}
        @model = agent.llm_model.to_s.strip
        @reasoning_effort = pick_effort(overrides["reasoning_effort"], agent.reasoning_effort)
      end

      # What the turn actually ran with, for the record kept on the reply.
      def to_h
        { "model" => model, "reasoning_effort" => reasoning_effort }.compact
      end

      private

      def pick_effort(*candidates)
        allowed = self.class.efforts_for(model)
        candidates.map { |value| value.to_s.strip }.find { |value| allowed.include?(value) }
      end
    end
  end
end
