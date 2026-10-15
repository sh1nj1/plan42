# frozen_string_literal: true

module Collavre
  module Orchestration
    # Keep job admission shares the controls' topic -> creative lock order.
    # Only task creation is locked; agent execution happens after commit.
    module KeepDispatchAdmission
      GENERATION_KEYS = %w[start_comment_id current_comment_id trigger_topic_id].freeze
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
        return yield unless generation

        result = :rejected
        Comments::TopicMutation.call(context.dig("topic", "id"), context.dig("creative", "id")) do
          creative = Creative.find_by(id: context.dig("creative", "id"))
          next unless creative

          creative.with_lock do
            next unless current?(creative, generation)

            result = Creatives::PermissionChecker.current_allowed?(creative.id, agent, :feedback) ? yield : :rejected
            release_rejected(creative, context) if result == :rejected || !result
          end
        end
        result
      end

      def current?(creative, generation)
        config = creative.data&.dig("trigger", "loop") || {}
        config["source"] == "keep" && config["state"] == "running" &&
          generation.keys.sort == GENERATION_KEYS.sort && config.slice(*GENERATION_KEYS) == generation
      end

      def release_rejected(creative, context)
        comment_id = context.dig("comment", "id")
        covering = Task.find_by(id: context.dig("comment", "keep_restore_task_id"), creative_id: creative.id)
        if covering
          DeliveryRecord.release_restore_claim!(covering, comment_id)
          DeliveryRecord.reject_restore!(covering, comment_id)
          creative.reload
        end
        return unless current?(creative, context.dig("comment", "keep_loop_generation"))
        return if owned?(creative, comment_id)

        config = creative.data.dig("trigger", "loop")
        config["state"] = "awaiting_user"
        config["control_version"] = config.fetch("control_version", 0) + 1
        creative.update!(data: creative.data)
      end

      def owned?(creative, comment_id)
        config = creative.data.dig("trigger", "loop")
        Task.where(creative_id: creative.id, topic_id: config["trigger_topic_id"], trigger_event_name: "comment_created").any? do |task|
          task.creative = creative
          (creative.trigger_loop_task?(task) && (task.active? || task.send(:trigger_loop_completion_eligible?))) ||
            DeliveryRecord.pending_restoration?(task, comment_id: comment_id)
        end
      end
    end
  end
end
