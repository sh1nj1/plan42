# frozen_string_literal: true

module Collavre
  module Crons
    class RecurringTaskIndex
      include RecurringTaskArguments

      KEY_PATTERN = /\Acron_(\d+)_/.freeze
      EMPTY_TASKS = [].freeze

      def initialize(scope: SolidQueue::RecurringTask.dynamic)
        @scope = scope
      end

      def creative_ids
        tasks_by_creative_id.keys
      end

      def tasks_for(creative_id)
        tasks_by_creative_id.fetch(creative_id.to_i, EMPTY_TASKS)
      end

      def tasks_for_topic(creative_id, topic_id, main_topic_id: nil)
        tasks_for(creative_id).select do |task|
          scheduled_topic_id = parse_arguments(task)["topic_id"]&.to_i
          scheduled_topic_id == topic_id.to_i ||
            (scheduled_topic_id.nil? && main_topic_id.to_i == topic_id.to_i)
        end
      end

      private

      attr_reader :scope

      def tasks_by_creative_id
        @tasks_by_creative_id ||= begin
          tasks = parsed_tasks
          effective_ids = Creatives::EffectiveCreativeResolution.effective_creative_ids(tasks.map(&:last))

          tasks.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(task, creative_id), index|
            index[effective_ids.fetch(creative_id)] << task
          end
        end
      end

      def parsed_tasks
        scope.select(:id, :key, :schedule, :arguments).order(:key).filter_map do |task|
          creative_id = task.key.match(KEY_PATTERN)&.[](1)&.to_i
          [ task, creative_id ] if creative_id
        end
      end
    end
  end
end
