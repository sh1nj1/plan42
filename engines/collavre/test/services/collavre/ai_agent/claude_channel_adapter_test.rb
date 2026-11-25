# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class ClaudeChannelAdapterTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)

        @agent = User.create!(
          email: "cc-adapter-test@agent.collavre.local",
          password: SecureRandom.hex(32),
          name: "Claude CC Test",
          llm_vendor: "anthropic",
          llm_model: "claude-code",
          created_by_id: @user.id,
          searchable: false
        )

        inbox = Creative.inbox_for(@user)
        @topic = inbox.topics.create!(name: "Test Topic", user: @user)

        @context = {
          "comment" => { "id" => 1, "content" => "Hello Claude" },
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        }
      end

      test "broadcasts dispatch event to agent topic channel" do
        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context).deliver
        end

        topic_dispatch = broadcasts.find { |b| b[:channel] == "agent:topic:#{@topic.id}" }
        assert_not_nil topic_dispatch
        assert_equal "dispatch", topic_dispatch[:data][:type]
        assert_equal @agent.id, topic_dispatch[:data][:agent_id]
        assert_equal "Hello Claude", topic_dispatch[:data][:comment][:content]
        assert_equal 1, topic_dispatch[:data][:comment][:id]
        assert_equal @topic.id, topic_dispatch[:data][:comment][:topic_id]
        assert_equal @creative.id, topic_dispatch[:data][:comment][:creative_id]
      end

      test "broadcasts dispatch to per-agent stream so MCP plugin receives it regardless of topic" do
        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context).deliver
        end

        agent_dispatch = broadcasts.find { |b| b[:channel] == "agent:user:#{@agent.id}" }
        assert_not_nil agent_dispatch, "expected broadcast on agent:user:#{@agent.id} so MCP plugin (subscribed by agent_id) receives the dispatch even when topic_id is a non-inbox creative"
        assert_equal "dispatch", agent_dispatch[:data][:type]
        assert_equal @topic.id, agent_dispatch[:data][:comment][:topic_id]
      end

      test "broadcast includes task_id when task is provided" do
        task = Collavre::Task.create!(
          name: "Response to comment_created",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: @topic.id,
          creative_id: @creative.id
        )

        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context, task: task).deliver
        end

        dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
        assert_not_nil dispatch
        assert_equal task.id, dispatch[:data][:task_id]
        assert_nil dispatch[:data][:execution_generation]
      end

      test "broadcast carries the task's execution generation for the reply to echo" do
        task = Collavre::Task.create!(
          name: "Response to comment_created", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: Orchestration::ExecutionFence.stamp(@context)
        )

        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context, task: task).deliver
        end

        dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
        assert_equal Orchestration::ExecutionFence.generation(task), dispatch[:data][:execution_generation]
      end

      test "broadcast task_id is nil when task is not provided" do
        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context).deliver
        end

        dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
        assert_not_nil dispatch
        assert_nil dispatch[:data][:task_id]
      end

      test "dispatch flags a session topic (session_id present) so siblings can ignore it" do
        @topic.update!(session_id: "sess-abc")

        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context).deliver
        end

        dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
        assert_equal true, dispatch[:data][:session_topic],
          "a session-mapped topic must be flagged so only its owning session handles it"
      end

      test "dispatch flags a work topic (no session_id) as non-session" do
        # @topic has no session_id — a project/work topic the agent was matched
        # onto via routing_expression. Any live session may take it; the flag
        # being false is what lets the client allow that.
        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
          ClaudeChannelAdapter.new(agent: @agent, context: @context).deliver
        end

        dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
        assert_equal false, dispatch[:data][:session_topic]
      end

      test "handoff is started durably before either broadcast and completed afterwards" do
        task, adapter = tracked_dispatch
        count = 0
        ActionCable.server.stub :broadcast, ->(*) {
          count += 1
          assert_equal "started", task.reload.trigger_event_payload.dig("channel_handoff", "state")
        } do
          adapter.deliver
        end
        assert_equal 2, count
        assert_equal "completed", task.reload.trigger_event_payload.dig("channel_handoff", "state")
        assert_equal "attempt", task.trigger_event_payload.dig("channel_handoff", "generation")
      end

      test "broadcast failure leaves uncertain handoff started so recovery cannot replay it" do
        task, adapter = tracked_dispatch
        ActionCable.server.stub :broadcast, ->(*) { raise IOError, "connection lost" } do
          assert_raises(IOError) { adapter.deliver }
        end
        assert_equal "started", task.reload.trigger_event_payload.dig("channel_handoff", "state")
      end

      test "partial broadcast failure also leaves handoff started" do
        task, adapter = tracked_dispatch
        agent_deliveries = 0
        AgentChannel.stub :broadcast_to_agent, ->(*) { agent_deliveries += 1 } do
          AgentChannel.stub :broadcast_to_topic, ->(*) { raise IOError, "topic stream lost" } do
            assert_raises(IOError) { adapter.deliver }
          end
        end
        assert_equal 1, agent_deliveries
        assert_equal "started", task.reload.trigger_event_payload.dig("channel_handoff", "state")
      end

      test "old adapter completion cannot overwrite a replacement generation" do
        task, adapter = tracked_dispatch
        AgentChannel.stub :broadcast_to_agent, ->(*) {
          task.update!(trigger_event_payload: { "execution_generation" => "replacement",
            "channel_handoff" => { "generation" => "replacement", "state" => "pending" } })
        } do
          AgentChannel.stub(:broadcast_to_topic, nil) { adapter.deliver }
        end
        assert_equal({ "generation" => "replacement", "state" => "pending" },
          task.reload.trigger_event_payload["channel_handoff"])
      end

      test "repeated delivery cannot broadcast the same tracked attempt twice" do
        _task, adapter = tracked_dispatch
        count = 0
        ActionCable.server.stub :broadcast, ->(*) { count += 1 } do
          2.times { adapter.deliver }
        end
        assert_equal 2, count
      end

      test "cancelled or replaced attempt cannot start its handoff" do
        task, adapter = tracked_dispatch
        task.update!(status: "cancelled")
        ActionCable.server.stub :broadcast, ->(*) { flunk "cancelled attempt broadcast" } do
          assert_not adapter.deliver
        end
        task.update!(status: "delegated", trigger_event_payload: { "execution_generation" => "replacement" })
        ActionCable.server.stub :broadcast, ->(*) { flunk "stale attempt broadcast" } do
          assert_not adapter.deliver
        end
      end

      test "immediate reply during broadcast cannot be overwritten by handoff completion" do
        task, adapter = tracked_dispatch
        ActionCable.server.stub :broadcast, ->(*) { task.update!(status: "done") } do
          adapter.deliver
        end
        assert_equal "done", task.reload.status
        assert_equal "started", task.trigger_event_payload.dig("channel_handoff", "state")
      end

      test "raises UndeliverableError when topic_id is missing" do
        adapter = ClaudeChannelAdapter.new(
          agent: @agent,
          context: { "comment" => { "id" => 1 } }
        )

        assert_raises(ClaudeChannelAdapter::UndeliverableError) { adapter.deliver }
      end
      private

      def tracked_dispatch
        task = Task.create!(name: "Tracked channel dispatch", status: "delegated", agent: @agent,
          topic_id: @topic.id, creative_id: @creative.id, trigger_event_payload: {
            "execution_generation" => "attempt",
            "channel_handoff" => { "generation" => "attempt", "state" => "pending" }
          })
        [ task, ClaudeChannelAdapter.new(agent: @agent, context: @context, task: task) ]
      end
    end
  end
end
