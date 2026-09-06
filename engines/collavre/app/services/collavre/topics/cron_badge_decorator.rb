# frozen_string_literal: true

module Collavre
  module Topics
    class CronBadgeDecorator
      def initialize(creative, main_topic_id, can_delete, view_context)
        @creative = creative
        @main_topic_id = main_topic_id
        @can_delete = can_delete
        @view_context = view_context
        @task_index = Crons::RecurringTaskIndex.new
      end

      def call(payload, topic)
        tasks = @task_index.tasks_for_topic(
          @creative.id,
          topic.id,
          main_topic_id: @main_topic_id
        )
        return payload if tasks.empty?

        payload.merge(
          cron_badge_html: @view_context.render_cron_badge(
            tasks,
            creative_id: @creative.id,
            can_delete: @can_delete
          )
        )
      end
    end
  end
end
