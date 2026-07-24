# frozen_string_literal: true

require "test_helper"

module Collavre
  class AgentSubscriptionTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @agent = User.create!(
        email: "agent-subscription-model-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Session Agent",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        created_by_id: @user.id,
        searchable: false
      )
    end

    test "live scope includes a freshly created row" do
      row = AgentSubscription.create!(agent_id: @agent.id, token: "fresh")

      assert_includes AgentSubscription.live, row
    end

    test "live scope excludes a row whose last_seen_at is past the staleness window" do
      row = AgentSubscription.create!(agent_id: @agent.id, token: "stale")
      row.update_column(:last_seen_at, (AgentSubscription::STALE_AFTER + 10.seconds).ago)

      refute_includes AgentSubscription.live, row
      assert_includes AgentSubscription.stale, row
    end

    test "reap_stale! deletes only rows past the staleness window for the agent" do
      fresh = AgentSubscription.create!(agent_id: @agent.id, token: "fresh")
      stale = AgentSubscription.create!(agent_id: @agent.id, token: "stale")
      stale.update_column(:last_seen_at, (AgentSubscription::STALE_AFTER + 1.minute).ago)

      AgentSubscription.reap_stale!(@agent.id)

      assert AgentSubscription.exists?(id: fresh.id), "live row must survive reaping"
      refute AgentSubscription.exists?(id: stale.id), "stale row must be reaped"
    end

    test "touch! refreshes last_seen_at for the matching token" do
      row = AgentSubscription.create!(agent_id: @agent.id, token: "beat")
      row.update_column(:last_seen_at, 1.hour.ago)

      AgentSubscription.touch!(@agent.id, "beat")

      assert_operator row.reload.last_seen_at, :>, 1.minute.ago
    end
  end
end
