# frozen_string_literal: true

module Collavre
  module Orchestration
    # Keeps only comments that may become a deferred task's next trigger.
    class DeferredTriggerScope
      SELF_AUTHORED_COMMENT_ID_KEY = "self_authored_trigger_comment_id"

      def self.for(task, context)
        new(task, context).relation
      end

      def self.reanchor_payload(task, context, comment)
        payload = TaskCoalescer.reanchor_payload(context, comment)
        deliberate_id = context[SELF_AUTHORED_COMMENT_ID_KEY]
        return payload unless deliberate_id.to_i == comment.id && comment.user_id == task.agent_id

        context.key?("sender") ? payload.merge("sender" => context["sender"]) : payload.except("sender")
      end

      def initialize(task, context)
        @task = task
        @context = context
      end

      def relation
        scope = Comment.public_only.without_approval_action
          .where(creative_id: @context.dig("creative", "id"), topic_id: @context.dig("topic", "id"))
        eligible = scope.where.not(user_id: [ @task.agent_id, nil ])
        eligible = eligible.or(deliberate_self_trigger(scope)) if deliberate_self_trigger_id
        eligible = eligible.where.not(id: review_message_ids)

        TaskCoalescer.reanchor_scope_for_workspace_principal(eligible.order(id: :desc), @task)
      end

      private

      def deliberate_self_trigger(scope)
        scope.where(id: deliberate_self_trigger_id, user_id: @task.agent_id)
      end

      def deliberate_self_trigger_id
        @context[SELF_AUTHORED_COMMENT_ID_KEY]
      end

      def review_message_ids
        Comment.review_messages
          .where(creative_id: @context.dig("creative", "id"), topic_id: @context.dig("topic", "id"))
          .select(:id)
      end
    end
  end
end
