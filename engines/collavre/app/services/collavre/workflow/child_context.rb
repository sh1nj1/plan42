# frozen_string_literal: true

module Collavre
  module Workflow
    class ChildContext
      def initialize(execution, admissions)
        @execution, @admissions = execution, admissions
      end

      def build
        reply = Comment.find(@admissions.first.reload.reply_comment_id)
        child = SystemEvents::Envelope.child(@execution.emits,
          parent: @execution.context["event"], source: "workflow")
        context = reply.dispatch_payload.deep_stringify_keys
        context["chat"] = { "content" => reply.content, "mentioned_users" => [] }
        context["workspace_user_id"] = principal
        context["event"] = child.to_h
        context["event_name"] = child.name
        context["workflow"] = { "execution_id" => @execution.id, "rule_id" => @execution.rule_id,
          "task_ids" => @admissions.map { |row| row.task.id },
          "reply_comment_ids" => @admissions.map { |row| row.reload.reply_comment_id } }
        SystemEvents::ContextBuilder.new(context).build
      end

      private

      def principal
        input = @execution.context
        return input["workspace_user_id"] if input.key?("workspace_user_id")
        user = User.find_by(id: input.dig("comment", "user_id"))
        user.id if user && !user.ai_user?
      end
    end
  end
end
