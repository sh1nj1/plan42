require "test_helper"

module Collavre
  module AiAgent
    class AgentLifecycleManagerTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @creative = Creative.create!(user: @owner, description: "Lifecycle creative")
        @main_topic = @creative.main_topic
        @other_topic = @creative.topics.create!(name: "Other", user: @owner)
        @agent = User.create!(
          email: "lifecycle_agent@example.com",
          name: "Lifecycle Agent",
          password: "password",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash",
          routing_expression: "true",
          searchable: true
        )
      end

      test "topic_id_for follows task, payload, comment, and Main precedence" do
        trigger_comment = @creative.comments.create!(
          content: "Workflow request",
          user: @owner,
          topic: @other_topic,
          skip_dispatch: true
        )

        task = Task.new(
          topic_id: @main_topic.id,
          trigger_event_payload: {
            "topic" => { "id" => @other_topic.id },
            "comment" => { "id" => trigger_comment.id }
          }
        )
        assert_equal @main_topic.id, AgentLifecycleManager.topic_id_for(task: task, creative: @creative)

        task.topic_id = nil
        assert_equal @other_topic.id, AgentLifecycleManager.topic_id_for(task: task, creative: @creative)

        task.trigger_event_payload.delete("topic")
        assert_equal @other_topic.id, AgentLifecycleManager.topic_id_for(task: task, creative: @creative)

        task.trigger_event_payload.delete("comment")
        assert_equal @main_topic.id, AgentLifecycleManager.topic_id_for(task: task, creative: @creative)
      end

      test "broadcast_status uses the trigger comment topic for workflow tasks" do
        trigger_comment = @creative.comments.create!(
          content: "Workflow request",
          user: @owner,
          topic: @other_topic,
          skip_dispatch: true
        )
        task = Task.create!(
          name: "Workflow response",
          status: "running",
          trigger_event_name: "workflow",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "comment" => { "id" => trigger_comment.id }
          },
          agent: @agent
        )
        broadcasts = []
        lifecycle = AgentLifecycleManager.new(task: task, agent: @agent, creative: @creative)

        CommentsPresenceChannel.stub :broadcast_agent_status, ->(*args, **kwargs) {
          broadcasts << [ args, kwargs ]
        } do
          lifecycle.broadcast_status("thinking")
        end

        assert_equal @other_topic.id, broadcasts.first.last[:topic_id]
      end

      test "deadline check preserves an external terminal transition that wins the row lock" do
        task = Task.create!(
          name: "Workflow response",
          status: "running",
          trigger_event_name: "workflow",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          agent: @agent
        )
        lifecycle = AgentLifecycleManager.new(task: task, agent: @agent, creative: @creative)
        lifecycle.instance_variable_set(:@last_cancel_check_at, -Float::INFINITY)
        lifecycle.instance_variable_set(:@deadline_at, -Float::INFINITY)

        external_transition = lambda do |_task|
          task.update!(status: "cancelled")
          false
        end

        error = Orchestration::DeliveryRecord.stub(:fail_while_worker_settles!, external_transition) do
          assert_raises(Collavre::CancelledError) { lifecycle.check_cancelled! }
        end

        assert_instance_of Collavre::CancelledError, error,
                           "a lost deadline race must not be classified as TurnDeadlineError"
        assert_equal "cancelled", task.reload.status
      end
    end
  end
end
