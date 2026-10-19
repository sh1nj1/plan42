# frozen_string_literal: true

module Collavre
  module Orchestration
    # Keep job admission shares the controls' topic -> creative lock order.
    # Only task creation is locked; agent execution happens after commit.
    module KeepDispatchAdmission
      module_function

      # Rebuilding the same anchor must not turn stale keep work into ordinary work.
      def reanchor_comment(payload, comment)
        dispatch = comment.dispatch_payload.slice(:comment).deep_stringify_keys
        return dispatch unless payload.dig("comment", "id").to_i == comment.id

        identity = payload.fetch("comment", {}).slice("keep_loop_generation", "keep_restore_task_id")
        dispatch["comment"].merge!(identity)
        dispatch
      end

      def call(context, agent)
        generation = context&.dig("comment", "keep_loop_generation")
        return yield unless KeepLoop.dispatch?(context)

        result = :rejected
        Comments::TopicMutation.call(context.dig("topic", "id"), context.dig("creative", "id")) do
          creative = Creative.find_by(id: context.dig("creative", "id"))
          next unless creative

          creative.with_lock do
            # This job no longer needs its queued reservation to hold the turn.
            KeepQueuedDispatches.release!(context, agent)
            creative.reload
            next unless current?(creative, generation, context.dig("comment", "id"))

            result = Creatives::PermissionChecker.current_allowed?(creative.id, agent, :feedback) ? yield : :rejected
            release_rejected(creative, context) if result == :rejected || !result
          end
        end
        result
      end

      def current?(creative, generation, comment_id)
        creative.data&.dig("trigger", "loop", "state") == "running" &&
          KeepLoop.admit!(creative, generation: generation, comment_id: comment_id)
      end

      def release_rejected(creative, context)
        comment_id = context.dig("comment", "id")
        covering = Task.find_by(id: context.dig("comment", "keep_restore_task_id"), creative_id: creative.id)
        if covering
          DeliveryRecord.release_restore_claim!(covering, comment_id)
          DeliveryRecord.reject_restore!(covering, comment_id)
          creative.reload
        end
        return unless current?(creative, context.dig("comment", "keep_loop_generation"), comment_id)
        return if owned?(creative, comment_id)

        config = creative.data.dig("trigger", "loop")
        config["state"] = "awaiting_user"
        config["control_version"] = config.fetch("control_version", 0) + 1
        creative.update!(data: creative.data)
      end

      def owned?(creative, comment_id)
        config = creative.data.dig("trigger", "loop")
        Task.where(creative_id: creative.id, topic_id: config["trigger_topic_id"], trigger_event_name: KeepLoop::TURN_EVENTS).any? do |task|
          task.creative = creative
          next false unless KeepLoop.turn?(task)

          (creative.trigger_loop_task?(task) && (task.active? || task.send(:owned_loop_check?))) ||
            DeliveryRecord.pending_restoration?(task, comment_id: comment_id)
        end || KeepQueuedDispatches.pending?(creative, comment_id)
      end
    end
  end
end
