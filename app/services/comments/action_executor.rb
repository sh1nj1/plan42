require "json"

module Comments
  class ActionExecutor
    class ExecutionError < StandardError; end

    def initialize(comment:, executor:)
      @comment = comment
      @executor = executor
    end

    def call
      comment.with_lock do
        prepare_for_execution!

        execute_within_transaction!
      end
    rescue ExecutionError
      raise
    rescue StandardError, ScriptError => e
      Rails.logger.error("Comment action execution failed: #{e.class} #{e.message}")
      raise ExecutionError, I18n.t("comments.approve_execution_failed", message: e.message)
    end

    private

    attr_reader :comment, :executor

    def prepare_for_execution!
      comment.reload
      raise ExecutionError, I18n.t("comments.approve_missing_action") if comment.action.blank?

      unless comment.can_be_approved_by?(executor)
        if comment.approver_id.blank?
          raise ExecutionError, I18n.t("comments.approve_missing_approver")
        else
          raise ExecutionError, I18n.t("comments.approve_not_allowed")
        end
      end
      if comment.action_executed_at.present?
        raise ExecutionError, I18n.t("comments.approve_already_executed")
      end
    end

    def execute_within_transaction!
      ApplicationRecord.transaction do
        execute_action!
        mark_execution_completed!
      end
    end

    def mark_execution_completed!
      comment.action_executed_at = Time.current
      comment.action_executed_by = executor
      comment.save!
    end

    def execute_action!
      ExecutionContext.new(comment).evaluate(comment.action)
    rescue ExecutionContext::InvalidActionError => e
      raise ExecutionError, e.message
    end

    class ExecutionContext
      class InvalidActionError < StandardError; end

      SUPPORTED_ACTIONS = {
        "create_creative" => :create_creative,
        "update_creative" => :update_creative,
        "approve_tool" => :approve_tool
      }.freeze

      CREATIVE_ATTRIBUTES = %w[description progress].freeze

      def initialize(comment)
        @comment = comment
      end

      attr_reader :comment

      def evaluate(code)
        payload = parse_payload(code)

        actions = Array(payload["actions"])
        if actions.present?
          Comment.transaction do
            actions.each do |action_payload|
              process_action(action_payload)
            end
          end
        else
          process_action(payload)
        end
      end

      private

      def parse_payload(code)
        raise InvalidActionError, I18n.t("comments.approve_missing_action") if code.blank?

        payload = JSON.parse(code)
        unless payload.is_a?(Hash)
          raise InvalidActionError, I18n.t("comments.approve_invalid_format")
        end

        deep_stringify_keys(payload)
      rescue JSON::ParserError
        raise InvalidActionError, I18n.t("comments.approve_invalid_format")
      end

      def deep_stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, inner_value), acc|
            acc[key.to_s] = deep_stringify_keys(inner_value)
          end
        when Array
          value.map { |item| deep_stringify_keys(item) }
        else
          value
        end
      end

      def create_creative(payload)
        attributes = extract_attributes(payload)
        parent = parent_creative_for(payload)

        new_creative = parent.children.build
        new_creative.user = parent.user || comment.user || Current.user
        assign_creative_attributes(new_creative, attributes)
        new_creative.save!
      rescue ActiveRecord::RecordInvalid => e
        raise InvalidActionError, e.record.errors.full_messages.to_sentence
      end

      def update_creative(payload)
        creative = find_target_creative(payload)
        attributes = extract_attributes(payload)

        assign_creative_attributes(creative, attributes)
        creative.save!
      rescue ActiveRecord::RecordInvalid => e
        raise InvalidActionError, e.record.errors.full_messages.to_sentence
      end

      def approve_tool(payload)
        tool_name = payload["tool_name"]
        raise InvalidActionError, "Tool name is required" if tool_name.blank?

        tool = McpTool.find_by(creative: comment.creative, name: tool_name)
        raise InvalidActionError, "Tool '#{tool_name}' not found" unless tool

        tool.approve!
      end

      def process_action(payload)
        unless payload.is_a?(Hash)
          raise InvalidActionError, I18n.t("comments.approve_invalid_format")
        end

        action = payload["action"] || payload["type"]
        raise InvalidActionError, I18n.t("comments.approve_missing_action") if action.blank?

        handler = SUPPORTED_ACTIONS[action]
        unless handler
          raise InvalidActionError, I18n.t("comments.approve_unsupported_action", action: action)
        end

        send(handler, payload)
      end

      def extract_attributes(payload)
        attributes = payload["attributes"]
        unless attributes.is_a?(Hash)
          raise InvalidActionError, I18n.t("comments.approve_invalid_attributes")
        end

        sanitized = attributes.slice(*CREATIVE_ATTRIBUTES)
        if sanitized.empty?
          raise InvalidActionError, I18n.t("comments.approve_no_attributes")
        end

        deep_stringify_keys(validate_attribute_types(sanitized))
      end

      def validate_attribute_types(attributes)
        attributes.each do |key, value|
          case key.to_s
          when "description"
            unless value.is_a?(String)
              raise InvalidActionError, I18n.t("comments.approve_invalid_description")
            end
          when "progress"
            unless value.is_a?(Numeric)
              raise InvalidActionError, I18n.t("comments.approve_invalid_progress")
            end
          end
        end

        attributes
      end

      def assign_creative_attributes(record, attributes)
        assignable = attributes.except("description")
        record.assign_attributes(assignable)
        if attributes.key?("description")
          record.description = attributes["description"]
        end
      end

      def find_target_creative(payload)
        creative_id = payload["creative_id"]
        return comment.creative if creative_id.blank?

        creative = find_creative_in_comment_tree(creative_id)
        unless creative
          raise InvalidActionError, I18n.t("comments.approve_invalid_creative")
        end

        creative
      end

      def parent_creative_for(payload)
        parent_id = payload["parent_id"]
        return comment.creative if parent_id.blank?

        creative = find_creative_in_comment_tree(parent_id)
        unless creative
          raise InvalidActionError, I18n.t("comments.approve_invalid_creative")
        end

        creative
      end

      def find_creative_in_comment_tree(creative_id)
        id = creative_id.to_i
        return if id <= 0

        creative = Creative.find_by(id: id)
        return unless creative

        return creative if allowed_creative_ids.include?(creative.id)

        origin = creative.effective_origin
        return origin if origin && allowed_creative_ids.include?(origin.id)

        nil
      end

      def allowed_creative_ids
        @allowed_creative_ids ||= comment.creative.self_and_descendants.pluck(:id)
      end
    end
  end
end
