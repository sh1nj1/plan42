# frozen_string_literal: true

module Collavre
  module Tools
    # Follow envelope causation, not correlation (which includes sibling work).
    # A bounded traversal fails closed instead of reporting partial work as done.
    module TaskDescendants
      MAX_TASKS = 200
      module_function

      def collect(roots)
        tasks = roots.index_by(&:id)
        frontier = roots
        loop do
          events = frontier.filter_map { |task| SystemEvents::Envelope.in(task.trigger_event_payload)&.id }.uniq
          successor_ids = TaskLineage.successor_ids!(frontier)
          related = children(events).or(Task.where(id: successor_ids))
          frontier = related.where.not(id: tasks.keys).limit(MAX_TASKS + 1).to_a
          break if frontier.empty?
          TaskTracking.invalid!(:too_many_tasks) if tasks.size + frontier.size > MAX_TASKS

          frontier.each { |task| tasks[task.id] = task }
        end
        tasks.values
      end

      def children(event_ids)
        Task.where(event_causation_id: event_ids).includes(:agent)
      end
    end
  end
end
