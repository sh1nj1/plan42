# frozen_string_literal: true

require "test_helper"

module Collavre
  class CronActionJobTest < ActiveJob::TestCase
    setup do
      @user = users(:one)
      @agent = users(:ai_bot)
      @creative = creatives(:tshirt)
      @topic = Collavre::Topic.create!(
        name: "Cron Job Topic",
        creative: @creative,
        user: @user
      )
    end

    teardown do
      @topic&.destroy
    end

    test "creates a comment in the creative topic" do
      assert_difference -> { Collavre::Comment.count }, 1 do
        CronActionJob.perform_now(
          creative_id: @creative.id,
          topic_id: @topic.id,
          agent_id: @agent.id,
          message: "Scheduled check-in"
        )
      end

      comment = Collavre::Comment.last
      assert_equal "Scheduled check-in", comment.content
      assert_equal @agent.id, comment.user_id
      assert_equal @topic.id, comment.topic_id
      assert_equal false, comment.private
    end

    test "handles missing creative gracefully" do
      assert_no_difference -> { Collavre::Comment.count } do
        CronActionJob.perform_now(
          creative_id: 999_999,
          topic_id: @topic.id,
          agent_id: @agent.id,
          message: "test"
        )
      end
    end

    test "handles missing topic gracefully" do
      assert_no_difference -> { Collavre::Comment.count } do
        CronActionJob.perform_now(
          creative_id: @creative.id,
          topic_id: 999_999,
          agent_id: @agent.id,
          message: "test"
        )
      end
    end

    test "handles missing agent gracefully" do
      assert_no_difference -> { Collavre::Comment.count } do
        CronActionJob.perform_now(
          creative_id: @creative.id,
          topic_id: @topic.id,
          agent_id: 999_999,
          message: "test"
        )
      end
    end
  end
end
