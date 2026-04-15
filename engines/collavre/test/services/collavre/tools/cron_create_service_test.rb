# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CronCreateServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @main_topic = @creative.main_topic(fallback_user: @user)
        @topic = Collavre::Topic.create!(
          name: "Cron Test Topic",
          creative: @creative,
          user: @user
        )
        Current.user = @user
      end

      teardown do
        SolidQueue::RecurringTask.where(static: false).destroy_all
        @topic&.destroy
        Current.user = nil
      end

      test "creates a recurring task with topic_name" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 9 * * *",
          message: "Daily check-in",
          description: "Morning check"
        )

        assert result[:success]
        assert result[:key].start_with?("cron_#{@creative.id}_")
        assert_equal "Cron Test Topic", result[:topic_name]

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        assert_not_nil task
        assert_equal false, task.static
        assert_equal "Collavre::CronActionJob", task.class_name
        assert_equal "0 9 * * *", task.schedule
        assert_equal "Morning check", task.description

        args = task.arguments.first
        assert_equal @topic.id, args[:topic_id]
      end

      test "topic_name Main resolves to Main topic_id" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Main",
          schedule: "0 9 * * *",
          message: "Main topic message"
        )

        assert result[:success]

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        args = task.arguments.first
        assert_equal @main_topic.id, args[:topic_id]
      end

      test "topic_name main (lowercase) returns error" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "main",
          schedule: "0 9 * * *",
          message: "Main topic message"
        )

        assert result[:error]
        assert_match(/Topic 'main' not found/, result[:error])
      end

      test "stores arguments for CronActionJob" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 9 * * *",
          message: "Test message"
        )

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        args = task.arguments.first
        assert_equal @creative.id, args[:creative_id]
        assert_equal @topic.id, args[:topic_id]
        assert_equal @user.id, args[:agent_id]
        assert_equal "Test message", args[:message]
      end

      test "rejects invalid cron schedule" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "not a valid schedule",
          message: "test"
        )

        assert result[:error]
        assert_match(/Invalid cron schedule/, result[:error])
      end

      test "rejects when creative not found" do
        result = CronCreateService.new.call(
          creative_id: 999_999,
          topic_name: "Main",
          schedule: "0 9 * * *",
          message: "test"
        )

        assert_equal "Creative not found", result[:error]
      end

      test "rejects when topic_name not found" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Nonexistent Topic",
          schedule: "0 9 * * *",
          message: "test"
        )

        assert result[:error]
        assert_match(/Topic 'Nonexistent Topic' not found/, result[:error])
      end

      test "generates unique keys" do
        result1 = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 9 * * *",
          message: "test 1"
        )
        result2 = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 10 * * *",
          message: "test 2"
        )

        assert_not_equal result1[:key], result2[:key]
      end
    end
  end
end
