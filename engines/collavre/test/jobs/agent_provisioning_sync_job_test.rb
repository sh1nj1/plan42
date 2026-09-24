# frozen_string_literal: true

require "test_helper"

class Collavre::AgentProvisioningSyncJobTest < ActiveSupport::TestCase
  setup do
    @owner = users(:two)
    @gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Sync job gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      workspace_mode: :per_user,
      identity_secret: "s" * 32
    )
    @agent = Collavre::User.create!(
      name: "Sync job agent",
      email: "sync-job-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )
    @first = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    @second = Collavre::AgentWorkspace.resolve!(agent: @agent, user: users(:one))
  end

  test "syncs every workspace of the agent and keeps going past a failure" do
    synced = []
    build = lambda do |gateway:, workspace:|
      assert_equal @gateway, gateway
      Object.new.tap do |client|
        client.define_singleton_method(:provision_sync) do
          synced << workspace.id
          raise Collavre::CliProxy::Client::Error.new("down", status: 502, code: "manifest_fetch_failed") if synced.one?
        end
      end
    end

    Collavre::CliProxy::Client.stub(:new, build) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end

    assert_equal [ @first.id, @second.id ].sort, synced.sort
  end

  test "does nothing for a missing, non-proxy or inactive-gateway agent" do
    calls = 0
    counter = ->(**) { calls += 1 }

    Collavre::CliProxy::Client.stub(:new, counter) do
      Collavre::AgentProvisioningSyncJob.perform_now(0)
      @gateway.update_columns(active: false)
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
      @agent.update_columns(llm_vendor: "openai")
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end

    assert_equal 0, calls
  end
end
