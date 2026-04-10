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

        dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
        assert_not_nil dispatch
        assert_equal "agent:topic:#{@topic.id}", dispatch[:channel]
        assert_equal @agent.id, dispatch[:data][:agent_id]
        assert_equal "Hello Claude", dispatch[:data][:comment][:content]
        assert_equal 1, dispatch[:data][:comment][:id]
        assert_equal @topic.id, dispatch[:data][:comment][:topic_id]
        assert_equal @creative.id, dispatch[:data][:comment][:creative_id]
      end

      test "handles missing topic_id gracefully" do
        adapter = ClaudeChannelAdapter.new(
          agent: @agent,
          context: { "comment" => { "id" => 1 } }
        )

        assert_nothing_raised { adapter.deliver }
      end
    end
  end
end
