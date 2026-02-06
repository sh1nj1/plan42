# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CronListServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Collavre::Topic.create!(
          name: "Cron List Topic",
          creative: @creative,
          user: @user
        )
        Current.user = @user

        @task = SolidQueue::RecurringTask.create!(
          key: "cron_#{@creative.id}_listtest",
          class_name: "Collavre::CronActionJob",
          schedule: "0 9 * * *",
          static: false,
          description: "Test cron",
          arguments: [{
            creative_id: @creative.id,
            topic_id: @topic.id,
            agent_id: @user.id,
            message: "Hello"
          }]
        )
      end

      teardown do
        SolidQueue::RecurringTask.where(static: false).destroy_all
        @topic&.destroy
        Current.user = nil
      end

      test "lists cron jobs for accessible creatives" do
        result = CronListService.new.call
        assert result[:success]
        assert result[:count] >= 1

        keys = result[:cron_jobs].map { |j| j[:key] }
        assert_includes keys, @task.key
      end

      test "filters by creative_id" do
        result = CronListService.new.call(creative_id: @creative.id)
        assert result[:success]
        assert result[:count] >= 1
        result[:cron_jobs].each do |job|
          assert_equal @creative.id, job[:creative_id]
        end
      end

      test "returns error for nonexistent creative" do
        result = CronListService.new.call(creative_id: 999_999)
        assert result[:error]
      end

      test "does not list static tasks" do
        SolidQueue::RecurringTask.create!(
          key: "static_test_list",
          class_name: "InboxSummaryJob",
          schedule: "0 9 * * *",
          static: true
        )

        result = CronListService.new.call
        keys = result[:cron_jobs].map { |j| j[:key] }
        assert_not_includes keys, "static_test_list"
      ensure
        SolidQueue::RecurringTask.find_by(key: "static_test_list")&.destroy
      end

      test "returns job details" do
        result = CronListService.new.call(creative_id: @creative.id)
        job = result[:cron_jobs].find { |j| j[:key] == @task.key }

        assert_not_nil job
        assert_equal "0 9 * * *", job[:schedule]
        assert_equal "Test cron", job[:description]
        assert_equal "Hello", job[:message]
      end
    end
  end
end
