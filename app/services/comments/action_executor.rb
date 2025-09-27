module Comments
  class ActionExecutor
    class ExecutionError < StandardError; end

    def initialize(comment:)
      @comment = comment
    end

    def call
      mark_execution_started!
      execute_action!
    rescue ExecutionError
      reset_execution_marker!
      raise
    rescue StandardError, ScriptError => e
      reset_execution_marker!
      Rails.logger.error("Comment action execution failed: #{e.class} #{e.message}")
      raise ExecutionError, I18n.t("comments.approve_execution_failed", message: e.message)
    end

    private

    attr_reader :comment

    def mark_execution_started!
      comment.with_lock do
        comment.reload
        raise ExecutionError, I18n.t("comments.approve_missing_action") if comment.action.blank?
        raise ExecutionError, I18n.t("comments.approve_missing_approver") if comment.approver_id.blank?
        if comment.action_executed_at.present?
          raise ExecutionError, I18n.t("comments.approve_already_executed")
        end

        comment.action_executed_at = Time.current
        comment.action_executed_by = comment.approver
        comment.save!
        @execution_marked = true
      end
    end

    def reset_execution_marker!
      return unless execution_marked?

      comment.with_lock do
        comment.update!(action_executed_at: nil, action_executed_by: nil)
      end
    ensure
      @execution_marked = false
    end

    def execution_marked?
      @execution_marked
    end

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
