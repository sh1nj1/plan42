# frozen_string_literal: true

module Collavre
  module Crons
    class RecurringTaskIndex
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

      private

      attr_reader :scope

      def tasks_by_creative_id
        @tasks_by_creative_id ||= scope.select(:key, :schedule).order(:key).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |task, index|
          creative_id = task.key.match(KEY_PATTERN)&.[](1)&.to_i
          index[creative_id] << task if creative_id
        end
      end
    end
  end
end
