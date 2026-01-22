module Collavre
  module Comments
    class ActionValidator
      class ValidationError < StandardError; end
  
      def initialize(comment:)
        @comment = comment
      end
  
      def validate!(code)
        context = ActionExecutor::ExecutionContext.new(comment)
        payload = context.send(:parse_payload, code)
        validate_payload(context, payload)
        payload
      rescue ActionExecutor::ExecutionContext::InvalidActionError => e
        raise ValidationError, e.message
      end
  
      private
  
      attr_reader :comment
  
      def validate_payload(context, payload)
        actions = payload["actions"]
        if actions.present?
          Array(actions).each do |action_payload|
            validate_single_action(context, action_payload)
          end
        else
          validate_single_action(context, payload)
        end
      end
  
      def validate_single_action(context, payload)
        unless payload.is_a?(Hash)
          raise ValidationError, I18n.t("comments.approve_invalid_format")
        end
  
        action = payload["action"] || payload["type"]
        raise ValidationError, I18n.t("comments.approve_missing_action") if action.blank?
  
        handler = ActionExecutor::ExecutionContext::SUPPORTED_ACTIONS[action]
        unless handler
          raise ValidationError, I18n.t("comments.approve_unsupported_action", action: action)
        end
  
        case handler
        when :create_creative
          context.send(:extract_attributes, payload)
          context.send(:parent_creative_for, payload)
        when :update_creative
          context.send(:extract_attributes, payload)
          context.send(:find_target_creative, payload)
        end
      end
    end
  end
end
