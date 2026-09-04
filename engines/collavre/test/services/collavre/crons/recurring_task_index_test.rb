# frozen_string_literal: true

require "test_helper"

module Collavre
  module Crons
    class RecurringTaskIndexTest < ActiveSupport::TestCase
      setup do
        @tasks = []
        @creative = creatives(:tshirt)
      end

      teardown do
        @tasks.each { |task| task.destroy! if task.persisted? }
      end

      test "groups cron tasks by creative id in key order" do
        later_key = "cron_#{@creative.id}_z_#{SecureRandom.hex(4)}"
        earlier_key = "cron_#{@creative.id}_a_#{SecureRandom.hex(4)}"
        create_task(key: later_key)
        create_task(key: earlier_key)
        create_task(key: "other_#{@creative.id}_#{SecureRandom.hex(4)}")

        index = RecurringTaskIndex.new

        assert_includes index.creative_ids, @creative.id
        assert_equal [ earlier_key, later_key ], index.tasks_for(@creative.id).map(&:key)
        assert_empty index.tasks_for(-1)
      end

      test "ignores static cron tasks" do
        create_task(key: "cron_#{@creative.id}_#{SecureRandom.hex(4)}", static: true)

        assert_empty RecurringTaskIndex.new.creative_ids
      end

      private

      def create_task(key:, static: false)
        @tasks << SolidQueue::RecurringTask.create!(
          key: key,
          class_name: "Collavre::CronActionJob",
          schedule: "0 9 * * *",
          static: static,
          arguments: []
        )
      end
    end
  end
end
