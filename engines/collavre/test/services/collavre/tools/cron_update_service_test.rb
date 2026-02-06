# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CronUpdateServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        Current.user = @user

        @task = SolidQueue::RecurringTask.create!(
          key: "cron_#{@creative.id}_updatetest",
          class_name: "Collavre::CronActionJob",
          schedule: "0 9 * * *",
          static: false,
          description: "Original description",
          arguments: [{
            creative_id: @creative.id,
            agent_id: @user.id,
            message: "original message"
          }]
        )
      end

      teardown do
        SolidQueue::RecurringTask.where(static: false).destroy_all
        Current.user = nil
      end

      test "updates schedule" do
        result = CronUpdateService.new.call(key: @task.key, schedule: "0 10 * * *")
        assert result[:success]

        task = SolidQueue::RecurringTask.find_by(key: @task.key)
        assert_equal "0 10 * * *", task.schedule
      end

      test "updates message in arguments" do
        result = CronUpdateService.new.call(key: @task.key, message: "new message")
        assert result[:success]

        task = SolidQueue::RecurringTask.find_by(key: @task.key)
        args = task.arguments.first
        assert_equal "new message", args[:message] || args["message"]
      end

      test "updates description" do
        result = CronUpdateService.new.call(key: @task.key, description: "Updated desc")
        assert result[:success]

        task = SolidQueue::RecurringTask.find_by(key: @task.key)
        assert_equal "Updated desc", task.description
      end

      test "rejects invalid schedule" do
        result = CronUpdateService.new.call(key: @task.key, schedule: "invalid")
        assert result[:error]
        assert_match(/Invalid cron schedule/, result[:error])

        # Schedule should not have changed
        task = SolidQueue::RecurringTask.find_by(key: @task.key)
        assert_equal "0 9 * * *", task.schedule
      end

      test "returns error for nonexistent key" do
        result = CronUpdateService.new.call(key: "nonexistent_key_xyz")
        assert result[:error]
      end

      test "does not update static tasks" do
        static_task = SolidQueue::RecurringTask.create!(
          key: "static_update_test",
          class_name: "InboxSummaryJob",
          schedule: "0 9 * * *",
          static: true
        )

        result = CronUpdateService.new.call(key: "static_update_test", schedule: "0 10 * * *")
        assert result[:error]
      ensure
        static_task&.destroy
      end
    end
  end
end
