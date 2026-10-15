# frozen_string_literal: true

module Collavre
  module Orchestration
    # A dropped keep dispatch remains tied to the generation that admitted it.
    module KeepDispatchRestoration
      KEY = "dropped_keep_turns"

      private

      def record_keep_drop(payload, task, comment_id, context)
        generation = context&.dig("comment", "keep_loop_generation") || current_keep_generation(task, comment_id)
        return payload unless generation

        turns = (payload[KEY] || {}).merge(comment_id.to_s => generation)
        payload.merge(KEY => turns)
      end

      def current_keep_generation(task, comment_id)
        config = Creative.where(id: task.creative_id).pick(:data)&.dig("trigger", "loop")
        return unless config && config["source"] == "keep" && config["current_comment_id"] == comment_id

        config.slice("start_comment_id", "current_comment_id", "trigger_topic_id")
      end

      def with_current_keep_restore(task, context)
        generation = Task.find_by(id: task.id)&.trigger_event_payload&.dig(KEY, context.dig("comment", "id").to_s)
        return yield unless generation

        creative = Creative.find_by(id: task.creative_id)
        return unless creative

        error = nil
        result = creative.with_lock do
          config = creative.data&.dig("trigger", "loop") || {}
          next unless config["source"] == "keep" && config["state"] == "running"
          next unless config.slice(*generation.keys) == generation

          begin
            yield
          rescue StandardError => failure
            error = failure
          end
        end
        raise error if error

        result
      end
    end
  end
end
