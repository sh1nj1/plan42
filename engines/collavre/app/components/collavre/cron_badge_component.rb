# frozen_string_literal: true

module Collavre
  class CronBadgeComponent < ViewComponent::Base
    include Crons::RecurringTaskArguments

    def initialize(tasks:, creative_id:, can_delete: false)
      @tasks = tasks
      @creative_id = creative_id
      @can_delete = can_delete
      @menu_id = "cron-badge-menu-#{SecureRandom.hex(4)}"
    end

    attr_reader :tasks, :creative_id, :menu_id

    def can_delete? = @can_delete

    def count_label
      t("collavre.creatives.index.cron_count", count: tasks.size)
    end

    def task_message(task)
      parse_arguments(task)["message"].presence || t("collavre.crons.not_available")
    end

    def next_run(task)
      task.next_time
    end

    def next_run_label(time)
      time ? helpers.l(time, format: :short) : t("collavre.crons.not_available")
    end

    def destroy_path(task)
      helpers.collavre.creative_cron_path(creative_id, task.key)
    end
  end
end
