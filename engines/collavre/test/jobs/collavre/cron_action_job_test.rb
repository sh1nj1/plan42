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
      before_count = @creative.comments.where(topic: @topic).count
      CronActionJob.perform_now(
        creative_id: @creative.id,
        topic_id: @topic.id,
        agent_id: @agent.id,
        message: "Scheduled check-in"
      )

      assert_equal before_count + 1, @creative.comments.where(topic: @topic).count
      comment = @creative.comments.where(topic: @topic).order(:id).last
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

    test "drops an enqueued cron action whose topic moved" do
      destination = Creative.create!(description: "Cron destination", user: @user)
      Collavre::Topics::TopicMove.new(topic: @topic, target_creative: destination).call

      assert_no_difference("Comment.count") do
        CronActionJob.perform_now(
          creative_id: @creative.id,
          topic_id: @topic.id,
          agent_id: @agent.id,
          message: "Stale scheduled check-in"
        )
      end

      assert_empty @creative.comments.where(content: "Stale scheduled check-in")
      assert_empty destination.comments.where(content: "Stale scheduled check-in")
    end

    # `topic_id: nil` describes the cron's *argument*, not the row: the comment
    # goes through Comment#assign_main_topic, which files it under the
    # creative's real Main topic. A payload that repeats the argument therefore
    # names a topic its own comment is not in — and every consumer downstream
    # (admission, the topic slot, the promotion refresh) believes the payload.
    test "a Main-topic cron names the topic its comment was filed under" do
      payload = nil
      SystemEvents::Dispatcher.stub(:dispatch, ->(_event, sent, **options) {
        payload = sent
        @dispatch_options = options
        []
      }) do
        CronActionJob.perform_now(
          creative_id: @creative.id,
          topic_id: nil,
          agent_id: @agent.id,
          message: "Main check-in"
        )
      end

      comment = @creative.comments.order(:id).last
      assert_not_nil comment.topic_id,
                     "assign_main_topic files a topic-less comment under Main"
      assert_equal comment.topic_id, payload.dig(:topic, :id),
                   "the dispatch payload must name the topic the comment lives in"
      assert_equal "cron", @dispatch_options[:source]
    end

    # Control: an explicit topic still round-trips. "Always resolve Main" would
    # pass the test above on its own while sending every cron to the wrong topic.
    test "an explicit cron topic is dispatched unchanged" do
      payload = nil
      SystemEvents::Dispatcher.stub(:dispatch, ->(_event, sent, **options) {
        payload = sent
        @dispatch_options = options
        []
      }) do
        CronActionJob.perform_now(
          creative_id: @creative.id,
          topic_id: @topic.id,
          agent_id: @agent.id,
          message: "Topic check-in"
        )
      end

      assert_equal @topic.id, payload.dig(:topic, :id)
      assert_equal "cron", @dispatch_options[:source]
    end
  end
end
