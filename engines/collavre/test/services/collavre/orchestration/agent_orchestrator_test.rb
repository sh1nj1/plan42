# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class AgentOrchestratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @ai_agent = users(:ai_bot)
        @creative = creatives(:tshirt)

        # Ensure AI agent has permission (searchable) for tests
        @ai_agent.update!(searchable: true)

        # Clear any existing routing expressions
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
      end

      test "dispatches to mentioned AI agent" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        # Verify the returned agents (jobs run inline in test)
        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent
      end

      test "does not dispatch when human is mentioned" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => {
            "content" => "@#{@user.name}: hello",
            "mentioned_user" => { "id" => @user.id }
          },
          "comment" => { "content" => "@#{@user.name}: hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_empty result
      end

      test "dispatches to agents matching routing expression" do
        @ai_agent.update!(routing_expression: 'event_name == "comment_created"')

        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent
      end

      test "does not dispatch when routing expression does not match" do
        @ai_agent.update!(routing_expression: 'event_name == "other_event"')

        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_not_includes result, @ai_agent
      end

      test "returns empty array when no agents match" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_empty result
      end

      # Deferred enqueue
      test "deferred decision creates queued task" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        # Create a running task to trigger topic concurrency limit
        Task.create!(name: "Running", status: "running", trigger_event_name: "e",
                     agent: @ai_agent, topic_id: topic.id)

        queued_count_before = Task.where(status: "queued", topic_id: topic.id).count
        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent

        queued_tasks = Task.where(status: "queued", topic_id: topic.id)
        assert_equal queued_count_before + 1, queued_tasks.count
        queued_task = queued_tasks.last
        assert_equal @ai_agent.id, queued_task.agent_id
        assert_equal topic.id, queued_task.topic_id
      end

      # dequeue_next_for_topic
      test "dequeue_next_for_topic claims queued task as pending" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          agent: @ai_agent, topic_id: topic.id
        )

        # dequeue_next_for_topic atomically claims the task as "pending"
        # (inline adapter will run the job immediately, changing status further,
        # so we verify via the atomic update count)
        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        # Task should no longer be "queued" — it was claimed and processed
        assert_not_equal "queued", queued_task.reload.status
      end

      test "dequeue_next_for_topic refreshes context with latest comment" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        # Original trigger comment
        original_comment = Comment.create!(
          creative: @creative, user: @user, content: "1", topic: topic
        )

        # Queued task with stale context pointing to original comment
        queued_task = Task.create!(
          name: "Queued task", status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id },
            "comment" => { "id" => original_comment.id, "content" => "1" },
            "chat" => { "content" => "1" }
          },
          agent: @ai_agent, topic_id: topic.id
        )

        # Agent1 replied "2" after the task was queued
        latest_comment = Comment.create!(
          creative: @creative, user: @ai_agent, content: "2", topic: topic
        )

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        # Context should now point to the latest comment
        refreshed = queued_task.reload.trigger_event_payload
        assert_equal latest_comment.id, refreshed.dig("comment", "id")
        assert_equal "2", refreshed.dig("comment", "content")
        assert_equal "2", refreshed.dig("chat", "content")
      end

      test "dequeue_next_for_topic does nothing when no queued tasks" do
        topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
        task_count_before = Task.count

        AgentOrchestrator.dequeue_next_for_topic(topic.id)

        assert_equal task_count_before, Task.count
      end

      test "dequeue_next_for_topic does nothing with nil topic_id" do
        task_count_before = Task.count

        AgentOrchestrator.dequeue_next_for_topic(nil)

        assert_equal task_count_before, Task.count
      end
    end
  end
end
