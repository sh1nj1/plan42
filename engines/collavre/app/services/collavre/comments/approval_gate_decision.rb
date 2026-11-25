# frozen_string_literal: true

module Collavre
  module Comments
    class ApprovalGateDecision
      class InvalidDecision < StandardError; end

      def initialize(comment, user)
        @comment, @user = comment, user
      end

      def call(decision, reason: nil)
        raise ArgumentError unless %w[approved denied].include?(decision)
        payload = @comment.approval_gate_action
        fail_with(:approve_invalid_format) unless payload
        if payload["mode"] == "async"
          return AsyncApprovalDecision.new(@comment, @user).call(decision, reason: reason)
        end
        task = Task.find_by(id: payload["task_id"])
        fail_with(:approve_task_not_pending) unless task

        task.with_lock do
          @comment.with_lock do
            validate!(task, payload)
            result = { decision: decision, reason: reason.to_s.strip.presence, decided_by: @user.id }
            @comment.update!(action: payload.merge("decision" => result).to_json,
              action_executed_at: Time.current, action_executed_by: @user)
            task.update!(pending_tool_call: task.pending_tool_call.merge("decision" => result))
            ApprovalGateResumeJob.perform_later(task.id, payload["tool_call_id"])
          end
        end
      end

      private

      def validate!(task, payload)
        fail_with(:approve_not_allowed) unless @comment.approval_status(@user) == :ok
        Tools::TopicAuthorizer.authorize_creative!(@comment.creative, :read, user: @user)
        fail_with(:approve_already_executed) if @comment.action_executed_at.present?
        fail_with(:approve_task_not_pending) unless task.pending_approval?
        pending = task.pending_tool_call
        unless pending&.dig("kind") == "approval_gate" && pending["tool_call_id"] == payload["tool_call_id"] &&
            task.agent_id == @comment.user_id && task.creative_id == @comment.creative_id && task.topic_id == @comment.topic_id
          fail_with(:approve_task_superseded)
        end
        fail_with(:approve_already_executed) if pending["decision"]
      end

      def fail_with(key)
        raise InvalidDecision, I18n.t("collavre.comments.#{key}")
      end
    end
  end
end
