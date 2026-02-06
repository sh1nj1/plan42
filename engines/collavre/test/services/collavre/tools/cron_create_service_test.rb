# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CronCreateServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
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

      test "creates a recurring task with correct attributes" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_id: @topic.id,
          schedule: "0 9 * * *",
          message: "Daily check-in",
          description: "Morning check"
        )

        assert result[:success]
        assert result[:key].start_with?("cron_#{@creative.id}_")

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        assert_not_nil task
        assert_equal false, task.static
        assert_equal "Collavre::CronActionJob", task.class_name
        assert_equal "0 9 * * *", task.schedule
        assert_equal "Morning check", task.description
      end

      test "stores arguments for CronActionJob" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_id: @topic.id,
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
          topic_id: @topic.id,
          schedule: "not a valid schedule",
          message: "test"
        )

        assert result[:error]
        assert_match(/Invalid cron schedule/, result[:error])
      end

      test "rejects when creative not found" do
        result = CronCreateService.new.call(
          creative_id: 999_999,
          topic_id: @topic.id,
          schedule: "0 9 * * *",
          message: "test"
        )

        assert_equal "Creative not found", result[:error]
      end

      test "rejects when topic does not belong to creative" do
        other_creative = creatives(:root_parent)
        other_topic = Collavre::Topic.create!(
          name: "Other Topic",
          creative: other_creative,
          user: @user
        )

        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_id: other_topic.id,
          schedule: "0 9 * * *",
          message: "test"
        )

        assert result[:error]
        assert_match(/Topic not found/, result[:error])
      ensure
        other_topic&.destroy
      end

      test "generates unique keys" do
        result1 = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_id: @topic.id,
          schedule: "0 9 * * *",
          message: "test 1"
        )
        result2 = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_id: @topic.id,
          schedule: "0 10 * * *",
          message: "test 2"
        )

        assert_not_equal result1[:key], result2[:key]
      end
    end
  end
end
