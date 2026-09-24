# frozen_string_literal: true

module Collavre
  module Comments
    class AsyncApprovalDecision < ApprovalGateDecision
      def call(decision, reason: nil)
        raise ArgumentError unless %w[approved denied].include?(decision)

        @comment.with_lock do
          payload = @comment.approval_gate_action
          validate_async!(payload)
          result = { decision: decision, reason: reason.to_s.strip.presence, decided_by: @user.id }
          @comment.update!(action: payload.merge("decision" => result).to_json,
                           action_executed_at: Time.current, action_executed_by: @user)
          ActiveRecord.after_all_transactions_commit { AsyncApprovalResumeJob.perform_later(@comment.id) }
        end
      end

      private

      def validate_async!(payload)
        fail_with(:approve_invalid_format) unless payload&.dig("mode") == "async"
        fail_with(:approve_not_allowed) unless @comment.approval_status(@user) == :ok
        Tools::TopicAuthorizer.authorize_creative!(@comment.creative, :read, user: @user)
        fail_with(:approve_already_executed) if @comment.action_executed_at || payload["decision"]
        origin = Task.find_by(id: payload["task_id"], agent_id: @comment.user_id,
                              creative_id: @comment.creative_id, topic_id: @comment.topic_id,
                              status: %w[running done])
        fail_with(:approve_task_superseded) unless origin&.agent&.cli_proxy_agent? && !@comment.private?
      end
    end
  end
end
