# frozen_string_literal: true

require "test_helper"

module Collavre
  class AgentChannelTest < ActionCable::Channel::TestCase
    tests Collavre::AgentChannel

    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @topic = @creative.topics.create!(name: "Agent Test Topic", user: @user)
    end

    test "subscribes successfully with valid topic and permission" do
      stub_connection current_user: @user
      subscribe topic_id: @topic.id

      assert subscription.confirmed?
      assert_has_stream "agent:topic:#{@topic.id}"
    end

    test "rejects subscription without topic_id or agent_id" do
      stub_connection current_user: @user
      subscribe

      assert subscription.rejected?
    end

    test "subscribes by agent_id when current_user owns the agent" do
      agent = User.create!(
        email: "agent-channel-owner-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Owned Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id

      assert subscription.confirmed?
      assert_has_stream "agent:user:#{agent.id}"
    end

    test "rejects agent_id subscription when current_user does not own the agent" do
      other = users(:two)
      agent = User.create!(
        email: "agent-channel-foreign-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Foreign Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        created_by_id: other.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id

      assert subscription.rejected?
    end

    test "rejects agent_id subscription for non-ai_user" do
      stub_connection current_user: @user
      subscribe agent_id: @user.id

      assert subscription.rejected?
    end

    test "rejects subscription without authentication" do
      stub_connection current_user: nil
      subscribe topic_id: @topic.id

      assert subscription.rejected?
    end

    test "rejects subscription for non-existent topic" do
      stub_connection current_user: @user
      subscribe topic_id: 999_999

      assert subscription.rejected?
    end

    test "rejects subscription when user lacks read permission" do
      other_user = users(:two)
      stub_connection current_user: other_user
      subscribe topic_id: @topic.id

      assert subscription.rejected?
    end

    test "broadcast_to_topic sends arbitrary payload" do
      payload = { type: "dispatch", agent_id: 1, comment: { id: 1, content: "test" } }

      assert_broadcast_on("agent:topic:#{@topic.id}", payload) do
        AgentChannel.broadcast_to_topic(@topic.id, payload)
      end
    end

    test "broadcast_to_agent sends to agent stream" do
      payload = { type: "dispatch", agent_id: 42, comment: { id: 9, content: "hi" } }

      assert_broadcast_on("agent:user:42", payload) do
        AgentChannel.broadcast_to_agent(42, payload)
      end
    end

    test "unsubscribe clears routing_expression on Claude Channel session agent" do
      agent = User.create!(
        email: "agent-channel-unsub-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: "true",
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      unsubscribe

      assert_nil agent.reload.routing_expression
    end

    test "resubscribe restores routing_expression cleared by prior unsubscribe" do
      agent = User.create!(
        email: "agent-channel-resub-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: "true",
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      unsubscribe
      assert_nil agent.reload.routing_expression

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      assert_equal "true", agent.reload.routing_expression
    end

    test "subscribe activates routing_expression on freshly-registered Claude agent" do
      # Closes the register-before-subscribe race: register() now creates the
      # ai_user with routing_expression=nil so the Matcher cannot select it
      # until a real subscriber exists for agent:user:<id>. The first cable
      # subscribe by the owner is the activation event — same code path that
      # restores routing on reconnect.
      agent = User.create!(
        email: "agent-channel-fresh-activate-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      assert_nil agent.routing_expression, "precondition: register left routing disabled"

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      # stream_from must be attached BEFORE routing_expression is activated,
      # otherwise a comment matched in the small window between the UPDATE
      # committing and stream_from registering the subscription would
      # broadcast into a stream with no subscriber.
      assert_has_stream "agent:user:#{agent.id}"
      assert_equal "true", agent.reload.routing_expression,
        "first owner subscribe must activate routing_expression so dispatches resume"
    end

    test "late unsubscribe does not clear routing when a newer subscribe already took over" do
      # Race: WS drops on the old connection, but ActionCable's ping-timeout
      # (default ~5s) means unsubscribed fires several seconds late. During
      # that window the MCP client reconnects → new Channel instance subscribes
      # → routing_expression is restored and the new connection is now the
      # live subscriber. The late unsubscribed for the OLD connection must NOT
      # clear routing — that would mark the live agent offline and stop
      # dispatches until another reconnect.
      agent = User.create!(
        email: "agent-channel-late-unsub-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )

      # Old connection subscribes; routing activates; capture the old token.
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?
      assert_equal "true", agent.reload.routing_expression
      old_token = AgentChannel.subscription_tokens[agent.id]
      assert old_token.present?

      # New (reconnected) connection subscribes BEFORE the old connection's
      # unsubscribed callback has had time to fire. This is a separate
      # Channel instance in real life — the implementation uses a class-
      # level token map to distinguish ownership across instances.
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?
      new_token = AgentChannel.subscription_tokens[agent.id]
      assert new_token.present?
      refute_equal old_token, new_token,
        "new subscribe must mint a fresh token so a stale unsubscribe is a no-op"

      # Simulate the OLD subscription's delayed unsubscribed firing AFTER the
      # new subscription has already claimed ownership.
      stale_channel = AgentChannel.allocate
      stale_channel.instance_variable_set(:@session_agent, agent)
      stale_channel.instance_variable_set(:@subscription_token, old_token)
      stale_channel.send(:unsubscribed)

      assert_equal "true", agent.reload.routing_expression,
        "late unsubscribe from a stale connection must not clobber the live subscription"
      assert_equal new_token, AgentChannel.subscription_tokens[agent.id],
        "the live connection's token must still be the registered owner"
    end

    test "unsubscribe does not touch non-Claude-Channel agent routing_expression" do
      agent = User.create!(
        email: "agent-channel-other-ai-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Other AI Agent",
        llm_vendor: "google",
        llm_model: "gemini-1.5-pro",
        routing_expression: "true",
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      unsubscribe

      assert_equal "true", agent.reload.routing_expression
    end
  end
end
