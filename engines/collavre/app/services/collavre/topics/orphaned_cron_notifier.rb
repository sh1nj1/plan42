# frozen_string_literal: true

require "json"

module Collavre
  module Topics
    # When a Topic is deleted, remove every non-static recurring cron task that
    # targets it and post a system message with a command that recreates the
    # original cron configuration.
    class OrphanedCronNotifier
      include Collavre::Crons::RecurringTaskArguments

      def initialize(topic_id:, topic_name:)
        @topic_id = topic_id
        @topic_name = topic_name
      end

      def call
        return if @topic_id.blank?

        tasks = matching_tasks
        tasks.each { |task, _args| task.destroy! }
        tasks.each do |task, args|
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

        # The recurring task stores the original (possibly linked/child) creative
        # id, but Comment#use_origin_creative rewrites the comment to the origin.
        # Post to the origin's Main topic so the notice stays on the origin and
        # is reachable from normal topic navigation (matches CronCreateService).
        main_topic = creative.effective_origin.main_topic
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
            cron_create_command: cron_create_command(task, creative, args)
          )
        )
      end

      def cron_create_command(task, creative, args)
        payload = {
          creative_id: creative.id,
          topic_name: @topic_name,
          schedule: task.schedule,
          message: args["message"],
          description: task.description
        }

        "/cron_create #{JSON.generate(payload)}"
      end
    end
  end
end
