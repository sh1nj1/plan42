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
