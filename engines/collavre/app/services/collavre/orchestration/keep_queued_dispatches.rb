# frozen_string_literal: true

module Collavre
  module Orchestration
    # Accepted keep jobs create their Task only when they run, so the current
    # turn records each queued agent until its job reaches admission. Stored
    # beside, not inside, the loop config so loop snapshots are unaffected.
    module KeepQueuedDispatches
      KEY = "keep_queued_dispatches"
      module_function

      def reserve!(context, agent)
        context = context.to_h.deep_stringify_keys
        comment_id = comment_id(context)
        return unless comment_id

        change(context.dig("creative", "id")) do |entry, creative|
          generation = context.dig("comment", "keep_loop_generation")
          next entry unless KeepLoop.admit!(creative, generation: generation, comment_id: comment_id)

          entry = { "comment_id" => comment_id, "generation" => generation, "agent_ids" => [] } unless
            entry&.dig("comment_id") == comment_id && entry["generation"] == generation
          entry.merge("agent_ids" => entry["agent_ids"] + [ agent.id ], "reserved_at" => Time.current.iso8601(6))
        end
      end

      def release!(context, agent)
        context = context.to_h.deep_stringify_keys
        comment_id = comment_id(context)
        return unless comment_id

        change(context.dig("creative", "id")) do |entry|
          next entry unless entry&.dig("comment_id") == comment_id && entry["generation"] == context.dig("comment", "keep_loop_generation")

          ids = entry["agent_ids"].dup
          index = ids.index(agent.id)
          ids.delete_at(index) if index
          ids.empty? ? nil : entry.merge("agent_ids" => ids)
        end
      end

      def pending?(creative, comment_id)
        entry = creative.data&.dig("trigger", KEY)
        entry.present? && entry["agent_ids"].present? &&
          KeepLoop.admit!(creative, generation: entry["generation"], comment_id: comment_id) && entry["comment_id"] == comment_id
      end

      # Restorations are owned by their covering task's claim instead.
      def comment_id(context)
        comment = context["comment"]
        return unless comment.is_a?(Hash) && comment["keep_loop_generation"] && !comment["keep_restore_task_id"]

        comment["id"]
      end

      def change(creative_id)
        creative = Creative.find_by(id: creative_id)
        return unless creative

        creative.with_lock do
          data = creative.data || {}
          trigger = data["trigger"] || {}
          entry = yield(trigger[KEY], creative)
          next if entry == trigger[KEY]

          entry ? trigger[KEY] = entry : trigger.delete(KEY)
          data["trigger"] = trigger
          creative.update!(data: data)
        end
      end
    end
  end
end
