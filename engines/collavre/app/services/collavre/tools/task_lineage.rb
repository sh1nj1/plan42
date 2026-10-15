# frozen_string_literal: true

module Collavre
  module Tools
    # The original instruction remains indexed even when a waiter is re-anchored.
    # Merged payloads also cover historical rows backfilled after that move.
    module TaskLineage
      module_function

      def for_comment(comment_id)
        indexed = Task.where(trigger_comment_id: comment_id)
        return indexed if indexed.exists?

        # Only historical re-anchored rows need the JSON fallback.
        Task.where(merged_condition, id: comment_id.to_s)
      end

      def merged_condition
        if Task.connection.adapter_name == "PostgreSQL"
          "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(trigger_event_payload::jsonb -> 'merged_comment_ids', '[]'::jsonb)) AS merged(value) WHERE merged.value = :id)"
        else
          "EXISTS (SELECT 1 FROM json_each(trigger_event_payload, '$.merged_comment_ids') AS merged WHERE CAST(merged.value AS TEXT) = :id)"
        end
      end

      def successors(tasks)
        TaskAction.where(task_id: tasks.map(&:id), action_type: "superseded").order(:id).each_with_object({}) do |action, map|
          id = action.payload&.dig("superseded_by_task_id").to_i
          raise ActiveRecord::RecordNotFound if id <= 0

          map[action.task_id] = id
        end
      end

      def successor_ids!(tasks)
        ids = successors(tasks).values.uniq
        raise ActiveRecord::RecordNotFound unless Task.where(id: ids).count == ids.size

        ids
      end

      def effective_tasks(tasks, successors)
        successors.each_key { |id| validate_chain!(id, successors) }
        tasks.reject { |task| successors.key?(task.id) }
      end
      def validate_chain!(id, successors)
        seen = {}
        while successors.key?(id)
          TaskTracking.invalid!(:invalid_lineage) if seen[id]
          seen[id] = true
          id = successors[id]
        end
      end
    end
  end
end
