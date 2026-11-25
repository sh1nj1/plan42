# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class ReviewHandlerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:two)
        @creative = Creative.create!(user: @user, description: "Test")
        @topic = Topic.create!(creative: @creative, name: "test", user: @user)
      end

      test "successive reviews keep each version's own run metadata" do
        comment = @creative.comments.create!(content: "Draft", user: @agent, topic: @topic)
        review = @creative.comments.create!(content: "Review", user: @user, topic: @topic, quoted_comment: comment)
        task = Task.create!(name: "Review", status: "running", agent: @agent)
        handler = ReviewHandler.new(review, @agent)
        review.stub(:review_message?, true) do
          handler.handle("First", task: task, agent_run_options: { "reasoning_effort" => "low" })
          handler.handle("Second", task: task, agent_run_options: { "reasoning_effort" => "high" })
        end
        versions = comment.comment_versions.order(:version_number)
        assert_equal [ "Draft", "First", "Second" ], versions.map(&:content)
        assert_equal [ nil, { "reasoning_effort" => "low" }, { "reasoning_effort" => "high" } ], versions.map(&:agent_run_options)
        assert_equal versions.last.agent_run_options, comment.reload.agent_run_options
      end

      test "eligible? returns false when original_comment is nil" do
        refute ReviewHandler.eligible?(nil, @agent)
      end

      test "eligible? returns false when comment is not a review message" do
        comment = @creative.comments.create!(
          content: "hello", user: @user, topic: @topic
        )
        refute ReviewHandler.eligible?(comment, @agent)
      end

      test "eligible? returns false when quoted comment belongs to different user" do
        other_comment = @creative.comments.create!(
          content: "other reply", user: @user, topic: @topic
        )
        review_comment = @creative.comments.create!(
          content: "review this", user: @user, topic: @topic,
          quoted_comment: other_comment
        )

        review_comment.stub(:review_message?, true) do
          refute ReviewHandler.eligible?(review_comment, @agent)
        end
      end

      test "eligible? returns true when all conditions met" do
        agent_comment = @creative.comments.create!(
          content: "agent reply", user: @agent, topic: @topic
        )
        review_comment = @creative.comments.create!(
          content: "review this", user: @user, topic: @topic,
          quoted_comment: agent_comment
        )

        review_comment.stub(:review_message?, true) do
          assert ReviewHandler.eligible?(review_comment, @agent)
        end
      end
    end
  end
end
