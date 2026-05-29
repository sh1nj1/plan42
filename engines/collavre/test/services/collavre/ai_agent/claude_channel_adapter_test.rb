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

      test "raises UndeliverableError when topic_id is missing" do
        adapter = ClaudeChannelAdapter.new(
          agent: @agent,
          context: { "comment" => { "id" => 1 } }
        )

        assert_raises(ClaudeChannelAdapter::UndeliverableError) { adapter.deliver }
      end
    end
  end
end
