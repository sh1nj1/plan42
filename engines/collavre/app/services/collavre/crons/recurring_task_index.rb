# frozen_string_literal: true

module Collavre
  module Crons
    class RecurringTaskIndex
      include RecurringTaskArguments

      KEY_PATTERN = /\Acron_(\d+)_/.freeze
      EMPTY_TASKS = [].freeze

      def self.for_creative_family(creative)
        for_creatives([ creative ])
      end

      def self.for_creatives(creatives)
        origin_ids = creatives.map { |creative| creative.origin_id || creative.id }.uniq
        return new(scope: SolidQueue::RecurringTask.none) if origin_ids.empty?

        creative_ids = origin_ids + Creative.where(origin_id: origin_ids).pluck(:id)
        patterns = creative_ids.map do |creative_id|
          "#{SolidQueue::RecurringTask.sanitize_sql_like("cron_#{creative_id}_")}%"
        end
        key_matches = SolidQueue::RecurringTask.arel_table[:key].matches_any(patterns, "\\")

        new(scope: SolidQueue::RecurringTask.dynamic.where(key_matches))
      end

      def initialize(scope: SolidQueue::RecurringTask.dynamic)
        @scope = scope
      end

      def creative_ids
        @creative_ids ||= begin
          ids = scope.pluck(:key).filter_map { |key| key.match(KEY_PATTERN)&.[](1)&.to_i }
          Creatives::EffectiveCreativeResolution.effective_creative_ids(ids).values.uniq
        end
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
          tasks = detailed_tasks
          effective_ids = Creatives::EffectiveCreativeResolution.effective_creative_ids(tasks.map(&:last))

          tasks.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(task, creative_id), index|
            index[effective_ids.fetch(creative_id)] << task
          end
        end
      end

      def detailed_tasks
        scope.select(:id, :key, :schedule, :arguments).order(:key).filter_map do |task|
          creative_id = task.key.match(KEY_PATTERN)&.[](1)&.to_i
          [ task, creative_id ] if creative_id
        end
      end
    end
  end
end
