# frozen_string_literal: true

require "test_helper"

module Collavre
  class AgentChannelTest < ActionCable::Channel::TestCase
    tests Collavre::AgentChannel

    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @topic = @creative.topics.create!(name: "Agent Test Topic", user: @user)
      # AgentChannel#unsubscribed enqueues CancelOfflineDelegatedTasksJob with
      # set(wait: ...). The default :async adapter raises NotImplementedError
      # for future-scheduled jobs; the :test adapter captures them for
      # assert_enqueued_with and is a no-op for tests that only care about
      # the routing/token side effects.
      @prev_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
    end

    teardown do
      ActiveJob::Base.queue_adapter = @prev_queue_adapter if @prev_queue_adapter
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

    test "unsubscribe removes Claude Channel presence without changing its routing expression" do
      agent = User.create!(
        email: "agent-channel-unsub-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: 'event_name == "comment_created"',
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      unsubscribe

      assert_equal 'event_name == "comment_created"', agent.reload.routing_expression
      assert_not agent.claude_channel_online?
    end

    test "resubscribe restores presence without changing the routing expression" do
      agent = User.create!(
        email: "agent-channel-resub-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: 'event_name == "comment_created"',
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      unsubscribe
      assert_not agent.claude_channel_online?

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      assert agent.claude_channel_online?
      assert_equal 'event_name == "comment_created"', agent.reload.routing_expression
    end

    test "subscribe creates presence for a freshly-registered Claude agent" do
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
      assert_nil agent.routing_expression, "precondition: no Liquid rule configured"

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      # stream_from must be attached BEFORE presence is created,
      # otherwise a comment matched in the small window between the UPDATE
      # committing and stream_from registering the subscription would
      # broadcast into a stream with no subscriber.
      assert_has_stream "agent:user:#{agent.id}"
      assert agent.claude_channel_online?,
        "first owner subscribe must make the agent routable through live presence"
      assert_nil agent.reload.routing_expression
    end

    test "late unsubscribe does not remove newer subscription presence" do
      # Race: WS drops on the old connection, but ActionCable's ping-timeout
      # (default ~5s) means unsubscribed fires several seconds late. During
      # that window the MCP client reconnects → new Channel instance subscribes
      # → a new presence row is created and the new connection is now the
      # live subscriber. The late unsubscribed for the OLD connection must NOT
      # remove the live row — that would mark the live agent offline and stop
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

      # Old connection subscribes; capture its token.
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?
      assert agent.claude_channel_online?
      old_token = agent.reload.routing_subscription_token
      assert old_token.present?

      # New (reconnected) connection subscribes BEFORE the old connection's
      # unsubscribed callback has had time to fire. The new subscribe
      # overwrites routing_subscription_token on the persisted row — this
      # is the cross-process ownership marker.
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?
      new_token = agent.reload.routing_subscription_token
      assert new_token.present?
      refute_equal old_token, new_token,
        "new subscribe must mint a fresh token so a stale unsubscribe is a no-op"

      # Simulate the OLD subscription's delayed unsubscribed firing AFTER the
      # new subscription has already claimed ownership.
      stale_channel = AgentChannel.allocate
      stale_channel.instance_variable_set(:@session_agent, agent)
      stale_channel.instance_variable_set(:@subscription_token, old_token)
      stale_channel.send(:unsubscribed)

      assert agent.claude_channel_online?,
        "late unsubscribe from a stale connection must not remove the live subscription"
      assert_equal new_token, agent.reload.routing_subscription_token,
        "the live connection's token must still be the registered owner"
    end

    test "cross-process: stale unsubscribe on one process does not clobber routing after reconnect on another" do
      # Codex P2 escalation: a per-process token map cannot tell whether a
      # late unsubscribe on Puma process A is stale relative to a fresh
      # subscribe on Puma process B (Solid Cable + WEB_CONCURRENCY > 1).
      # The ownership marker is now persisted on users.routing_subscription_token,
      # so a conditional UPDATE filtered by token is the cross-process check.
      agent = User.create!(
        email: "agent-channel-cross-process-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_subscription_token: "old-process-a-token",
        created_by_id: @user.id,
        searchable: false
      )

      # Simulate process B: reconnect subscribes here, overwrites the token
      # on the persisted row. (We bypass the Channel testing harness for the
      # stale process A instance below — that's the whole point: A's channel
      # state was never touched by B's subscribe.)
      agent.update_column(:routing_subscription_token, "new-process-b-token")

      # Process A's late unsubscribed: this Channel instance still holds
      # the OLD token in its instance variable. With per-process maps, A
      # would believe it still owns the slot. With the persisted ownership
      # marker, the stale presence deletion matches zero rows and is a no-op.
      AgentSubscription.create!(agent_id: agent.id, token: "new-process-b-token")
      stale_channel = AgentChannel.allocate
      stale_channel.instance_variable_set(:@session_agent, agent)
      stale_channel.instance_variable_set(:@subscription_token, "old-process-a-token")
      stale_channel.send(:unsubscribed)

      assert agent.claude_channel_online?,
        "stale unsubscribe on process A must not remove process B's live presence"
      assert_equal "new-process-b-token", agent.routing_subscription_token,
        "process B remains the registered owner across the stale unsubscribe"
    end

    test "unsubscribe schedules CancelOfflineDelegatedTasksJob with grace delay when token clear succeeds" do
      agent = User.create!(
        email: "agent-channel-grace-job-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        created_by_id: @user.id,
        searchable: false
      )

      ActiveJob::Base.queue_adapter = :test
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?
      token = agent.reload.routing_subscription_token
      assert token.present?

      assert_enqueued_with(
        job: Collavre::CancelOfflineDelegatedTasksJob,
        args: [ agent.id, token ]
      ) do
        unsubscribe
      end
    end

    test "stale unsubscribe does NOT schedule CancelOfflineDelegatedTasksJob (newer subscription owns cleanup)" do
      agent = User.create!(
        email: "agent-channel-stale-no-enqueue-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_subscription_token: "newer-token-owns-it",
        created_by_id: @user.id,
        searchable: false
      )

      ActiveJob::Base.queue_adapter = :test

      stale_channel = AgentChannel.allocate
      stale_channel.instance_variable_set(:@session_agent, agent)
      stale_channel.instance_variable_set(:@subscription_token, "stale-old-token")

      assert_no_enqueued_jobs(only: Collavre::CancelOfflineDelegatedTasksJob) do
        stale_channel.send(:unsubscribed)
      end
    end

    test "subscribe records a presence row for the Claude Channel session" do
      agent = User.create!(
        email: "agent-channel-presence-row-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      assert_equal 1, AgentSubscription.where(agent_id: agent.id).count,
        "each live session must register a presence row"
    end

    test "subscribe stamps the session_id on the presence row so the HTTP DELETE can correlate it" do
      # The HTTP unregister path drops the exiting session's OWN row before
      # deciding sibling liveness, but the WS token is server-minted and unknown
      # to that HTTP client. The plugin sends its stable session_id in the cable
      # subscribe; the presence row must record it so DELETE (which knows the
      # session via the topic) can target exactly this session's row.
      agent = User.create!(
        email: "agent-channel-session-id-row-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id, session_id: "sess-xyz"
      assert subscription.confirmed?

      row = AgentSubscription.find_by(agent_id: agent.id)
      assert row
      assert_equal "sess-xyz", row.session_id,
        "the presence row must record the session_id sent by the plugin"
    end

    test "concurrent sessions: unsubscribing one keeps presence active while a sibling remains" do
      # The headline multi-session fix: with the shared default agent, two
      # Claude Code sessions subscribe to the SAME agent:user:<id> stream. When
      # one ends, its unsubscribe must NOT remove presence or cancel work for the
      # still-live sibling.
      agent = User.create!(
        email: "agent-channel-sibling-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )

      # A sibling session is already subscribed (its own presence row).
      AgentSubscription.create!(agent_id: agent.id, token: "sibling-token")

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?
      assert agent.claude_channel_online?

      assert_no_enqueued_jobs(only: Collavre::CancelOfflineDelegatedTasksJob) do
        unsubscribe
      end

      assert agent.claude_channel_online?,
        "presence must stay active while the sibling session is still subscribed"
      assert AgentSubscription.where(agent_id: agent.id, token: "sibling-token").exists?,
        "the sibling's presence row must survive this session's unsubscribe"
    end

    test "unsubscribe schedules a session-scoped cancellation when a live sibling remains" do
      # Codex P2: when a session's WS drops without DELETE and a sibling keeps
      # the shared agent routable, routing is preserved — but the dropped
      # session's OWN session topic is private to it (siblings filter
      # session_topic dispatches to their own topic), so a task delegated there
      # would hold its ResourceTracker slot until stuck recovery. The WS-drop
      # path must schedule a grace-delayed, session-scoped cleanup, mirroring the
      # HTTP destroy path's cancel_tasks_for_topic for the still-live-sibling case.
      agent = User.create!(
        email: "agent-channel-sibling-session-cancel-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      AgentSubscription.create!(agent_id: agent.id, token: "sibling-token")

      ActiveJob::Base.queue_adapter = :test
      stub_connection current_user: @user
      subscribe agent_id: agent.id, session_id: "sess-drop"
      assert subscription.confirmed?
      token = agent.reload.routing_subscription_token

      assert_enqueued_with(
        job: Collavre::CancelOfflineDelegatedTasksJob,
        args: [ agent.id, token, "sess-drop" ]
      ) do
        unsubscribe
      end

      assert agent.claude_channel_online?,
        "presence must stay active for the still-live sibling"
    end

    test "last session unsubscribe removes the presence row" do
      agent = User.create!(
        email: "agent-channel-last-session-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert_equal 1, AgentSubscription.where(agent_id: agent.id).count

      unsubscribe

      assert_not agent.claude_channel_online?
      assert_equal 0, AgentSubscription.where(agent_id: agent.id).count,
        "the last session's presence row must be removed on unsubscribe"
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

    test "last session unsubscribe removes presence even when a crash-orphaned stale sibling row remains" do
      # Codex P2: presence rows are deleted only by unsubscribed, so a Puma/
      # ActionCable crash leaves a stale row behind. If a plain `exists?` gated
      # presence, that orphan would keep the agent routable forever — dispatching
      # into a dead stream. The live scope must ignore rows past STALE_AFTER so
      # this session, leaving cleanly, still becomes offline.
      agent = User.create!(
        email: "agent-channel-stale-sibling-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )

      crashed = AgentSubscription.create!(agent_id: agent.id, token: "crashed-process")
      crashed.update_column(:last_seen_at, (AgentSubscription::STALE_AFTER + 1.minute).ago)

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert agent.claude_channel_online?

      unsubscribe

      assert_not agent.claude_channel_online?,
        "a crash-orphaned stale sibling row must not keep presence on"
    end

    test "subscribe reaps crash-orphaned stale presence rows for the agent" do
      agent = User.create!(
        email: "agent-channel-reap-on-subscribe-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      stale = AgentSubscription.create!(agent_id: agent.id, token: "crashed-old")
      stale.update_column(:last_seen_at, (AgentSubscription::STALE_AFTER + 1.minute).ago)

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      assert subscription.confirmed?

      refute AgentSubscription.exists?(id: stale.id),
        "stale rows must be reaped when a new session subscribes to the agent"
    end

    test "replay_permissions re-broadcasts the recorded decision for a requested pending id" do
      # Codex P2 (pull-on-resubscribe): broadcast_claude_channel_permission_decision
      # fires once into the transient agent:user:<id> stream. If the plugin's
      # WebSocket was mid-reconnect when the approver clicked, the decision lands in
      # a subscriber-less stream and is lost — the server has already stamped
      # action_executed_at and hidden the buttons, so the suspended tool hangs with
      # no retry path. After every (re)subscribe the plugin sends the request_ids it
      # still holds pending; the server re-broadcasts the recorded decision for
      # exactly those. The plugin's pending set is the only bound — there is no
      # wall-clock window, so an outage of any length is covered.
      agent = create_claude_channel_agent("agent-channel-replay")
      creative = Collavre::Creative.create!(description: "Replay", user: @user, progress: 0.0)
      topic = creative.topics.create!(name: "replay session", user: @user)
      decided_permission_comment(
        agent: agent, creative: creative, topic: topic,
        request_id: "req-replay-1", decision: "allow",
        decided_at: 30.seconds.ago
      )

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      payloads = capture_broadcasts("agent:user:#{agent.id}") do
        perform :replay_permissions, request_ids: [ "req-replay-1" ]
      end

      decision = payloads.find { |p| p["type"] == "permission_decision" }
      assert decision, "a pulled pending id with a recorded decision must be replayed"
      assert_equal "req-replay-1", decision["request_id"]
      assert_equal "allow", decision["behavior"]
      assert_equal agent.id, decision["agent_id"]
    end

    test "replay_permissions does not replay a still-pending (undecided) permission" do
      # Only decisions the approver actually made are replayed. An undecided
      # prompt has no decision to deliver — replaying it would be meaningless and
      # could mislead the plugin's coordinator.
      agent = create_claude_channel_agent("agent-channel-replay-pending")
      creative = Collavre::Creative.create!(description: "Pending", user: @user, progress: 0.0)
      topic = creative.topics.create!(name: "pending session", user: @user)
      decided_permission_comment(
        agent: agent, creative: creative, topic: topic,
        request_id: "req-pending-1", decision: nil, decided_at: nil
      )

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      payloads = capture_broadcasts("agent:user:#{agent.id}") do
        perform :replay_permissions, request_ids: [ "req-pending-1" ]
      end

      refute payloads.any? { |p| p["type"] == "permission_decision" },
        "an undecided permission prompt has no decision to replay"
    end

    test "replay_permissions ignores decisions for ids the plugin did not request" do
      # The bound is the plugin's pending set, not a time window: only ids the
      # plugin still holds pending are replayed. A decision the plugin already
      # consumed (so it is absent from the requested set) is never re-broadcast,
      # so reconnect cannot resurface settled history — and, crucially, a long
      # outage drops nothing, because the still-pending id is what gets requested.
      agent = create_claude_channel_agent("agent-channel-replay-unrequested")
      creative = Collavre::Creative.create!(description: "Other", user: @user, progress: 0.0)
      topic = creative.topics.create!(name: "other session", user: @user)
      decided_permission_comment(
        agent: agent, creative: creative, topic: topic,
        request_id: "req-other-1", decision: "allow", decided_at: 30.seconds.ago
      )

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      payloads = capture_broadcasts("agent:user:#{agent.id}") do
        perform :replay_permissions, request_ids: [ "req-some-other-id" ]
      end

      refute payloads.any? { |p| p["type"] == "permission_decision" },
        "a decision for an id the plugin did not request must not be re-broadcast"
    end

    test "replay_permissions with no requested ids broadcasts nothing" do
      # A fresh (re)subscribe with an empty pending set (the common case) must be a
      # no-op — no scan, no broadcast.
      agent = create_claude_channel_agent("agent-channel-replay-empty")
      creative = Collavre::Creative.create!(description: "Empty", user: @user, progress: 0.0)
      topic = creative.topics.create!(name: "empty session", user: @user)
      decided_permission_comment(
        agent: agent, creative: creative, topic: topic,
        request_id: "req-empty-1", decision: "allow", decided_at: 30.seconds.ago
      )

      stub_connection current_user: @user
      subscribe agent_id: agent.id
      payloads = capture_broadcasts("agent:user:#{agent.id}") do
        perform :replay_permissions, request_ids: []
      end

      refute payloads.any? { |p| p["type"] == "permission_decision" },
        "an empty pending set must replay nothing"
    end

    test "subscribe alone does not replay any permission decision (pull-only, no window)" do
      # Replay is now pull-driven: subscribing does not auto-replay. Only an
      # explicit replay_permissions perform carrying the plugin's pending ids
      # triggers it, so there is no wall-clock window that could drop a decision
      # made during a long outage.
      agent = create_claude_channel_agent("agent-channel-replay-noauto")
      creative = Collavre::Creative.create!(description: "NoAuto", user: @user, progress: 0.0)
      topic = creative.topics.create!(name: "noauto session", user: @user)
      decided_permission_comment(
        agent: agent, creative: creative, topic: topic,
        request_id: "req-noauto-1", decision: "allow", decided_at: 30.seconds.ago
      )

      stub_connection current_user: @user
      payloads = capture_broadcasts("agent:user:#{agent.id}") do
        subscribe agent_id: agent.id
      end

      refute payloads.any? { |p| p["type"] == "permission_decision" },
        "subscribe must not auto-replay; replay is pull-driven via replay_permissions"
    end

    test "heartbeat refreshes the live session's presence last_seen_at" do
      agent = User.create!(
        email: "agent-channel-heartbeat-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
      stub_connection current_user: @user
      subscribe agent_id: agent.id
      row = AgentSubscription.find_by(agent_id: agent.id)
      assert row
      row.update_column(:last_seen_at, 1.hour.ago)

      subscription.send(:touch_presence)

      assert_operator row.reload.last_seen_at, :>, 1.minute.ago,
        "the periodic heartbeat must keep this session's presence row live"
    end

    private

    def create_claude_channel_agent(slug)
      User.create!(
        email: "#{slug}-#{SecureRandom.hex(4)}@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: nil,
        created_by_id: @user.id,
        searchable: false
      )
    end

    def decided_permission_comment(agent:, creative:, topic:, request_id:, decision:, decided_at:)
      payload = {
        "action" => Comment::ClaudeChannelPermission::ACTION_TYPE,
        "request_id" => request_id,
        "tool_name" => "Bash",
        "arguments" => { "command" => "ls" }
      }
      payload["decision"] = decision if decision
      comment = Comment.create!(
        creative: creative,
        topic: topic,
        user: agent,
        approver: @user,
        content: "needs approval",
        action: JSON.pretty_generate(payload),
        skip_default_user: true,
        skip_dispatch: true
      )
      comment.update_columns(action_executed_at: decided_at, action_executed_by_id: @user.id) if decided_at
      comment
    end
  end
end
