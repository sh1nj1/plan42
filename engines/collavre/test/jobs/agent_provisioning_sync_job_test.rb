# frozen_string_literal: true

require "test_helper"

class Collavre::AgentProvisioningSyncJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
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

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
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

  test "retries only failed workspaces after the rate limit window" do
    [ 429, 502 ].each do |status|
      clear_enqueued_jobs
      calls = []
      build = lambda do |gateway:, workspace:|
        Object.new.tap do |client|
          client.define_singleton_method(:provision_sync) do
            calls << workspace.id
            raise Collavre::CliProxy::Client::Error.new("limited", status: status) if workspace.id == @failed_id
          end
          client.instance_variable_set(:@failed_id, @first.id)
        end
      end
      freeze_time do
        Collavre::CliProxy::Client.stub(:new, build) do
          assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob,
                               args: [ @agent.id, { workspace_id: @first.id, attempt: 1 } ], at: 65.seconds.from_now) do
            Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
          end
        end
      end
      assert_equal [ @first.id, @second.id ].sort, calls.sort
      synced = []
      client = Object.new
      client.define_singleton_method(:provision_sync) { true }
      Collavre::CliProxy::Client.stub(:new, ->(gateway:, workspace:) { synced << workspace.id; client }) do
        perform_enqueued_jobs
      end
      assert_equal [ @first.id ], synced
    end
  end

  test "does not retry permanent failures or exhausted retries" do
    [ [ 403, 0 ], [ 502, 4 ] ].each do |status, attempt|
      client = Object.new
      client.define_singleton_method(:provision_sync) { raise Collavre::CliProxy::Client::Error.new("failed", status: status) }
      Collavre::CliProxy::Client.stub(:new, client) do
        assert_no_enqueued_jobs do
          Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id, attempt: attempt)
        end
      end
    end
  end

  test "a retry ignores removed workspaces" do
    id = @first.id
    @first.destroy!
    assert_not Collavre::AgentWorkspace.exists?(id)
    Collavre::CliProxy::Client.stub(:new, ->(**) { flunk "Removed workspace must not sync" }) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: id, attempt: 1)
    end
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
