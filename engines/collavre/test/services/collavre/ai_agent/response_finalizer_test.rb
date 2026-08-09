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
      # content folded into the quoted comment, which becomes the survivor.
      test "review workflow folds the reply into the surviving quoted comment" do
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

        assert_equal quoted.id, result.id, "quoted comment is the survivor"
        assert_not Comment.exists?(reply.id), "placeholder reply is destroyed"
      end

      # The reply placeholder's activity logs must move to the surviving comment so
      # the visible activity record is preserved across the fold.
      test "review workflow reassociates activity logs onto the survivor" do
        quoted = @creative.comments.create!(content: "agent draft", user: @agent, topic: @topic)
        review = @creative.comments.create!(
          content: "please revise", user: @user, topic: @topic, quoted_comment: quoted
        )
        reply = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic
        )
        ActivityLog.create!(comment: reply, user: @agent, activity: "reply_created")

        ResponseFinalizer.new(
          task: @task, agent: @agent, original_comment: review,
          reply_comment: reply, response_content: "revised content"
        ).finalize

        assert_equal quoted.id, ActivityLog.where(user: @agent).last.comment_id
      end

      test "an agent reply clears the onboarding mention waiting state" do
        @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
        Creative.inbox_for(@user)
        root = Onboarding::Seeder.call(user: @user)
        card = root.children.find { |creative| creative.onboarding_metadata["step_key"] == "mention_agent" }
        practice = card.children.sole
        @agent = users(:ai_bot)
        @task.update!(agent: @agent)
        perform_enqueued_jobs do
          CreativeShare.create!(creative: root, user: @agent, permission: :feedback, shared_by: @user)
        end
        mention = practice.comments.create!(
          content: "@#{@agent.name}: help me",
          user: @user,
          skip_dispatch: true
        )
        Onboarding::ProgressTracker.comment_created(comment: mention, user: @user)

        reply = ResponseFinalizer.new(
          task: @task,
          agent: @agent,
          original_comment: mention,
          reply_comment: nil,
          response_content: "Here is help"
        ).finalize

        assert_equal @agent, reply.user
        assert_equal "responded", card.reload.onboarding_metadata["response_status"]
      end
    end
  end
end
