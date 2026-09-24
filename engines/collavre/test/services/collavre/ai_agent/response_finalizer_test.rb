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

      test "does not recreate a reply after its source is deleted" do
        original = @creative.comments.create!(content: "Request", user: @user, topic: @topic)
        original.destroy!
        assert_no_difference([ "Comment.count", "TaskAction.count" ]) do
          assert_nil finalize_without_placeholder(original)
        end
      end

      test "rechecks source existence after acquiring the topic lock" do
        original = @creative.comments.create!(content: "Request", user: @user, topic: @topic)
        mutation = Comments::TopicMutation.method(:call)
        wrapper = ->(topic_id, creative_id, &block) do
          original.destroy!
          mutation.call(topic_id, creative_id, &block)
        end
        result = Comments::TopicMutation.stub(:call, wrapper) { finalize_without_placeholder(original) }
        assert_nil result
        assert_not Comment.exists?(task: @task)
      end

      test "creates final reply and action while holding the topic lock" do
        original = @creative.comments.create!(content: "Request", user: @user, topic: @topic)
        mutation = Comments::TopicMutation.method(:call)
        locked = false
        wrapper = ->(topic_id, creative_id, &block) do
          assert_equal [ @topic.id, @creative.id ], [ topic_id, creative_id ]
          mutation.call(topic_id, creative_id) do
            locked = true
            block.call
            assert_equal "Final answer", @task.reload.reply_comment.content
            assert_equal 1, @task.task_actions.where(action_type: "reply_created").count
          end
        end
        result = Comments::TopicMutation.stub(:call, wrapper) { finalize_without_placeholder(original) }
        assert locked
        assert_equal "Final answer", result.content
      end

      def finalize_without_placeholder(original)
        ResponseFinalizer.new(task: @task, agent: @agent, original_comment: original,
                              reply_comment: nil, response_content: "Final answer").finalize
      end

      # In the review workflow the agent's reply placeholder is destroyed and its
      # content folded into the quoted comment, which becomes the survivor.
      test "review workflow folds the reply into the surviving quoted comment" do
        quoted = @creative.comments.create!(content: "agent draft", user: @agent, topic: @topic)
        review = @creative.comments.create!(
          content: "please revise", user: @user, topic: @topic, quoted_comment: quoted
        )
        reply = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic, task: @task
        )

        result = ResponseFinalizer.new(
          task: @task, agent: @agent, original_comment: review,
          reply_comment: reply, response_content: "revised content"
        ).finalize

        assert_equal quoted.id, result.id, "quoted comment is the survivor"
        assert_not Comment.exists?(reply.id), "placeholder reply is destroyed"
        assert_equal @task.id, result.reload.task_id
        assert_equal quoted.id, @task.reload.reply_comment.id
      end

      [
        [ { "model" => "old-model", "reasoning_effort" => "low" },
          { "model" => "new-model", "reasoning_effort" => "high" } ],
        [ {}, { "model" => "new-model", "reasoning_effort" => "high" } ],
        [ { "model" => "old-model", "reasoning_effort" => "low" }, {} ]
      ].each_with_index do |(previous_options, current_options), index|
        test "review workflow replaces audit options with the latest run #{index}" do
          quoted = @creative.comments.create!(
            content: "agent draft", user: @agent, topic: @topic, agent_run_options: previous_options
          )
          review = @creative.comments.create!(
            content: "please revise", user: @user, topic: @topic, quoted_comment: quoted
          )
          reply = @creative.comments.create!(
            content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic,
            task: @task, agent_run_options: current_options
          )

          result = ResponseFinalizer.new(
            task: @task, agent: @agent, original_comment: review,
            reply_comment: reply, response_content: "revised content"
          ).finalize

          assert_equal quoted.id, result.id
          versions = quoted.comment_versions.order(:version_number)
          assert_equal [ previous_options, current_options ], versions.map(&:agent_run_options)
          assert_equal [ "agent draft", "revised content" ], versions.map(&:content)
          assert_equal current_options, quoted.reload.agent_run_options
          assert_equal "revised content", quoted.content
          assert_equal @task.id, quoted.task_id
          assert_not Comment.exists?(reply.id)
        end
      end

      # The reply placeholder's activity logs must move to the surviving comment so
      # the visible activity record is preserved across the fold.
      test "review workflow reassociates activity logs onto the survivor" do
        quoted = @creative.comments.create!(content: "agent draft", user: @agent, topic: @topic)
        review = @creative.comments.create!(
          content: "please revise", user: @user, topic: @topic, quoted_comment: quoted
        )
        reply = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: @topic, task: @task
        )
        ActivityLog.create!(comment: reply, user: @agent, activity: "reply_created")

        ResponseFinalizer.new(
          task: @task, agent: @agent, original_comment: review,
          reply_comment: reply, response_content: "revised content"
        ).finalize

        assert_equal quoted.id, ActivityLog.where(user: @agent).last.comment_id
      end
    end
  end
end
