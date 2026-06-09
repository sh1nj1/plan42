# frozen_string_literal: true

module Collavre
  module Crons
    # Shared parsing for SolidQueue::RecurringTask records that back our crons.
    # The cron's creative_id/topic_id/agent_id/message live inside the task's
    # `arguments` JSON (an array whose first element is the keyword hash), and
    # the creative id is also encoded in the key as `cron_<creative_id>_<hex>`.
    #
    # Included by CronListService and Topics::OrphanedCronNotifier so the
    # arguments format is parsed in exactly one place.
    module RecurringTaskArguments
      private

      def parse_arguments(task)
        args = task.arguments
        return {} unless args.is_a?(Array) && args.first.is_a?(Hash)

        args.first.stringify_keys
      end

      def parse_creative_id_from_key(key)
        match = key.match(/\Acron_(\d+)_/)
        match[1].to_i if match
      end
    end
  end
end
