# frozen_string_literal: true

module Collavre
  module Topics
    # When a Topic is deleted, find every non-static recurring cron task that
    # targets that topic (topic_id stored inside the task's arguments JSON) and
    # post a system message into the affected creative's Main topic so the user
    # knows the cron is now orphaned.
    #
    # Decision: notify only. The recurring task is intentionally left in place
    # so the user can decide whether to re-point or cancel it.
    class OrphanedCronNotifier
      include Collavre::Crons::RecurringTaskArguments

      def initialize(topic_id:, topic_name:)
        @topic_id = topic_id
        @topic_name = topic_name
      end

      def call
        return if @topic_id.blank?

        matching_tasks.each do |task, args|
          notify_for(task, args)
        end
      end

      private

      def matching_tasks
        SolidQueue::RecurringTask.where(static: false).filter_map do |task|
          args = parse_arguments(task)
          target = args["topic_id"]
          next if target.blank?
          next unless target.to_i == @topic_id.to_i

          [ task, args ]
        end
      end

      def notify_for(task, args)
        creative_id = args["creative_id"] || parse_creative_id_from_key(task.key)
        creative = Creative.find_by(id: creative_id)
        return unless creative

        main_topic = creative.main_topic
        return unless main_topic

        Comment.create!(
          creative: creative,
          topic_id: main_topic.id,
          user: nil, # System message
          skip_default_user: true, # keep user nil even when a deleter is Current.user; don't trigger AI orchestration
          content: I18n.t(
            "collavre.topics.orphaned_cron_notice",
            topic_name: @topic_name,
            cron_key: task.key,
            message: args["message"]
          )
        )
      end
    end
  end
end
