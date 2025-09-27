module Comments
  class ActionExecutor
    class ExecutionError < StandardError; end

    def initialize(comment:)
      @comment = comment
    end

    def call
      raise ExecutionError, I18n.t("comments.approve_missing_action") if comment.action.blank?
      raise ExecutionError, I18n.t("comments.approve_missing_approver") if comment.approver_id.blank?

      execute_action!
      comment.update!(action: nil, approver: nil)
    rescue ExecutionError
      raise
    rescue StandardError, ScriptError => e
      Rails.logger.error("Comment action execution failed: #{e.class} #{e.message}")
      raise ExecutionError, I18n.t("comments.approve_execution_failed", message: e.message)
    end

    private

    attr_reader :comment

    def execute_action!
      ExecutionContext.new(comment).evaluate(comment.action)
    rescue ExecutionContext::InvalidActionError => e
      raise ExecutionError, e.message
    end

    class ExecutionContext
      class InvalidActionError < StandardError; end

      def initialize(comment)
        @comment = comment
      end

      attr_reader :comment

      def evaluate(code)
        raise InvalidActionError, I18n.t("comments.approve_missing_action") if code.blank?

        instance_eval(code, __FILE__, __LINE__)
      end

      def creative
        comment.creative
      end

      def author
        comment.user
      end

      alias_method :user, :author

      def approver
        comment.approver
      end

      def context
        {
          comment_id: comment.id,
          creative_id: comment.creative_id,
          author_id: comment.user_id,
          approver_id: comment.approver_id
        }
      end
    end
  end
end
