# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CronCancelServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        Current.user = @user

        @task = SolidQueue::RecurringTask.create!(
          key: "cron_#{@creative.id}_canceltest",
          class_name: "Collavre::CronActionJob",
          schedule: "0 9 * * *",
          static: false,
          arguments: [{
            creative_id: @creative.id,
            agent_id: @user.id,
            message: "to cancel"
          }]
        )
      end

      teardown do
        SolidQueue::RecurringTask.where(static: false).destroy_all
        Current.user = nil
      end

      test "cancels an existing cron job" do
        result = CronCancelService.new.call(key: @task.key)
        assert result[:success]
        assert_nil SolidQueue::RecurringTask.find_by(key: @task.key)
      end

      test "returns error for nonexistent key" do
        result = CronCancelService.new.call(key: "nonexistent_key_xyz")
        assert result[:error]
      end

      test "does not cancel static tasks" do
        static_task = SolidQueue::RecurringTask.create!(
          key: "static_cancel_test",
          class_name: "InboxSummaryJob",
          schedule: "0 9 * * *",
          static: true
        )

        result = CronCancelService.new.call(key: "static_cancel_test")
        assert result[:error]
        assert_not_nil SolidQueue::RecurringTask.find_by(key: "static_cancel_test")
      ensure
        static_task&.destroy
      end

      test "returns success message with key" do
        result = CronCancelService.new.call(key: @task.key)
        assert_equal @task.key, result[:key]
        assert_match(/cancelled/, result[:message])
      end
    end
  end
end
