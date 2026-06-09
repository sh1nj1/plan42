# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class ResponseFinalizerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:two)
        @creative = Creative.create!(user: @user, description: "Test")
        @topic = Topic.create!(creative: @creative, name: "test", user: @user)
        @task = Task.create!(name: "Test", status: "running", agent: @agent)
      end

      # In the review workflow the agent's reply placeholder is destroyed and its
      # content folded into the quoted comment. The OpenClaw run_id (dedup marker)
      # must survive that destruction by moving to the quoted comment, otherwise a
      # later proactive delivery of the same run finds no marker and duplicates.
      test "review workflow carries openclaw_run_id onto the surviving quoted comment" do
        quoted = @creative.comments.create!(content: "agent draft", user: @agent, topic: @topic)
        review = @creative.comments.create!(
          content: "please revise", user: @user, topic: @topic, quoted_comment: quoted
        )
        reply = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic,
          openclaw_run_id: "run-review"
        )

        result = ResponseFinalizer.new(
          task: @task, agent: @agent, original_comment: review,
          reply_comment: reply, response_content: "revised content"
        ).finalize

        assert_equal quoted.id, result.id, "quoted comment is the survivor"
        assert_not Comment.exists?(reply.id), "placeholder reply is destroyed"
        assert ProcessedAiRun.processed?("run-review"),
               "run is durably recorded so a later re-delivery is suppressed"
        assert_equal "run-review", quoted.reload.openclaw_run_id,
                     "run_id is also carried to the surviving comment (single-review label)"
      end

      # A comment reviewed multiple times spans multiple runs but has a single
      # run_id column slot. Every run must still be durably recorded so a late
      # re-delivery of ANY of them is suppressed — the exact gap the tombstone
      # closes that the comment column cannot.
      test "repeated reviews of the same comment record every run durably" do
        quoted = @creative.comments.create!(content: "agent draft", user: @agent, topic: @topic)

        %w[run-A run-B run-C].each do |rid|
          review = @creative.comments.create!(
            content: "revise again", user: @user, topic: @topic, quoted_comment: quoted
          )
          reply = @creative.comments.create!(
            content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic,
            openclaw_run_id: rid
          )
          ResponseFinalizer.new(
            task: @task, agent: @agent, original_comment: review,
            reply_comment: reply, response_content: "content #{rid}"
          ).finalize
        end

        assert ProcessedAiRun.processed?("run-A"), "first run recorded"
        assert ProcessedAiRun.processed?("run-B"), "second run recorded"
        assert ProcessedAiRun.processed?("run-C"), "third run recorded"
      end

      # When the placeholder carried no run_id (e.g. HTTP transport or run_id never
      # arrived), the carry-over is a no-op and finalize still succeeds.
      test "review workflow without a run_id finalizes without error" do
        quoted = @creative.comments.create!(content: "agent draft", user: @agent, topic: @topic)
        review = @creative.comments.create!(
          content: "please revise", user: @user, topic: @topic, quoted_comment: quoted
        )
        reply = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic
        )

        result = ResponseFinalizer.new(
          task: @task, agent: @agent, original_comment: review,
          reply_comment: reply, response_content: "revised content"
        ).finalize

        assert_equal quoted.id, result.id
        assert_nil quoted.reload.openclaw_run_id
      end
    end
  end
end
