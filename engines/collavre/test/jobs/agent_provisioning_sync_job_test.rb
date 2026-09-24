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
    [ [ 429, nil ], [ 502, nil ], [ nil, "proxy_unreachable" ] ].each do |status, code|
      clear_enqueued_jobs
      calls = []
      build = lambda do |gateway:, workspace:|
        Object.new.tap do |client|
          client.define_singleton_method(:provision_sync) do
            calls << workspace.id
            raise Collavre::CliProxy::Client::Error.new("limited", status: status, code: code) if workspace.id == @failed_id
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

  test "does not retry permanent failures" do
    [ [ 403, nil, 0 ], [ 403, nil, 100 ], [ nil, "unknown_error", 0 ] ].each do |status, code, attempt|
      client = Object.new
      client.define_singleton_method(:provision_sync) { raise Collavre::CliProxy::Client::Error.new("failed", status: status, code: code) }
      Collavre::CliProxy::Client.stub(:new, client) do
        assert_no_enqueued_jobs do
          Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id, attempt: attempt)
        end
      end
    end
  end

  test "transient failures keep retrying beyond five windows with capped backoff" do
    [ [ 429, nil ], [ 502, "manifest_fetch_failed" ], [ nil, "proxy_unreachable" ] ].each do |status, code|
      client = Object.new
      client.define_singleton_method(:provision_sync) do
        raise Collavre::CliProxy::Client::Error.new("limited", status: status, code: code)
      end
      [ [ 4, 325 ], [ 5, 390 ], [ 100, 900 ] ].each do |attempt, delay|
        clear_enqueued_jobs
        freeze_time do
          Collavre::CliProxy::Client.stub(:new, client) do
            assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob,
                                 args: [ @agent.id, { workspace_id: @first.id, attempt: attempt + 1 } ],
                                 at: delay.seconds.from_now) do
              Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id, attempt: attempt)
            end
          end
        end
        assert_equal 1, enqueued_jobs.size
      end
    end
  end

  test "a successful late retry stops without syncing other workspaces" do
    client = Object.new
    client.define_singleton_method(:provision_sync) { true }
    synced = []
    Collavre::CliProxy::Client.stub(:new, ->(gateway:, workspace:) { synced << workspace.id; client }) do
      assert_no_enqueued_jobs do
        Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id, attempt: 100)
      end
    end
    assert_equal [ @first.id ], synced
  end

  test "a retry ignores removed workspaces" do
    id = @first.id
    @first.destroy!
    assert_not Collavre::AgentWorkspace.exists?(id)
    Collavre::CliProxy::Client.stub(:new, ->(**) { flunk "Removed workspace must not sync" }) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: id, attempt: 1)
    end
  end

  test "syncs retained workspaces after leaving CLI Proxy including retries" do
    @agent.update!(llm_vendor: "openai", llm_model: "gpt-5", codex_fast_mode: true)
    synced = []
    client = Object.new
    client.define_singleton_method(:provision_sync) { true }
    Collavre::CliProxy::Client.stub(:new, ->(gateway:, workspace:) { synced << workspace.id; client }) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id, attempt: 5)
    end
    assert_equal [ @first.id, @second.id ].sort, synced.first(2).sort
    assert_equal 2, synced.size
    assert_nil @agent.reload.agent_gateway_id
  end

  test "only successful off syncs revoke tokens and the final retry detaches" do
    @agent.update!(llm_vendor: "openai")
    first_token = Doorkeeper::AccessToken.by_token(@first.callback_token)
    second_token = Doorkeeper::AccessToken.by_token(@second.callback_token)
    build = lambda do |gateway:, workspace:|
      client = Object.new
      failed = workspace.id == @first.id
      client.define_singleton_method(:provision_sync) do
        raise Collavre::CliProxy::Client::Error.new("down", status: 502) if failed
        {}
      end
      client
    end
    Collavre::CliProxy::Client.stub(:new, build) { Collavre::AgentProvisioningSyncJob.perform_now(@agent.id) }
    assert_equal @gateway.id, @agent.reload.agent_gateway_id
    assert Collavre::AgentWorkspace.exists?(@first.id)
    refute Collavre::AgentWorkspace.exists?(@second.id)
    refute first_token.reload.revoked?
    assert second_token.reload.revoked?

    client = Object.new
    client.define_singleton_method(:provision_sync) { {} }
    Collavre::CliProxy::Client.stub(:new, client) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id, attempt: 1)
    end
    assert_nil @agent.reload.agent_gateway_id
    assert first_token.reload.revoked?
    assert @gateway.destroy
  end

  test "deactivation releases retired agents while an off sync retry is pending" do
    @agent.update!(llm_vendor: "openai")
    token = Doorkeeper::AccessToken.by_token(@first.callback_token)
    client = Object.new
    client.define_singleton_method(:provision_sync) { raise Collavre::CliProxy::Client::Error.new("down", status: 502) }
    Collavre::CliProxy::Client.stub(:new, client) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end
    @gateway.update!(active: false)
    assert_nil @agent.reload.agent_gateway_id
    assert token.reload.revoked?
    Collavre::CliProxy::Client.stub(:new, ->(**) { flunk "Inactive gateway must not be contacted" }) do
      perform_enqueued_jobs
    end
    assert @gateway.destroy
  end

  test "inactive retired gateway removes residual workspaces without proxy access" do
    @agent.update!(llm_vendor: "openai")
    token = Doorkeeper::AccessToken.by_token(@first.callback_token)
    @gateway.update_columns(active: false)
    Collavre::CliProxy::Client.stub(:new, ->(**) { flunk "Inactive gateway must not be contacted" }) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end
    assert_nil @agent.reload.agent_gateway_id
    assert token.reload.revoked?
    assert_empty @agent.agent_workspaces
  end

  test "permanent off sync failures revoke tokens and release the gateway" do
    @agent.update!(llm_vendor: "openai")
    token = Doorkeeper::AccessToken.by_token(@first.callback_token)
    client = Object.new
    client.define_singleton_method(:provision_sync) { raise Collavre::CliProxy::Client::Error.new("denied", status: 403) }
    Collavre::CliProxy::Client.stub(:new, client) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end
    assert_nil @agent.reload.agent_gateway_id
    assert token.reload.revoked?
    assert @gateway.destroy
  end

  test "sync errors in a successful HTTP response retain credentials for retry" do
    @agent.update!(llm_vendor: "openai")
    client = Object.new
    client.define_singleton_method(:provision_sync) { { "last_error" => "incomplete" } }
    Collavre::CliProxy::Client.stub(:new, client) do
      assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob,
                           args: [ @agent.id, { workspace_id: @first.id, attempt: 1 } ]) do
        Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id)
      end
    end
    assert Collavre::AgentWorkspace.exists?(@first.id)
    assert_equal @gateway.id, @agent.reload.agent_gateway_id
  end

  test "returning to CLI Proxy during sync preserves workspaces" do
    @agent.update!(llm_vendor: "openai")
    agent = @agent
    client = Object.new
    client.define_singleton_method(:provision_sync) { agent.update!(llm_vendor: "cli_proxy"); {} }
    Collavre::CliProxy::Client.stub(:new, client) { Collavre::AgentProvisioningSyncJob.perform_now(@agent.id) }
    assert_equal @gateway.id, @agent.reload.agent_gateway_id
    assert_equal 2, @agent.agent_workspaces.count
  end

  test "an agent without workspaces detaches without contacting the proxy" do
    @first.destroy!
    @second.destroy!
    @agent.update!(llm_vendor: "openai")
    Collavre::CliProxy::Client.stub(:new, ->(**) { flunk "No workspace needs syncing" }) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end
    assert_nil @agent.reload.agent_gateway_id
  end

  test "gateway reassignment during sync is not detached" do
    @agent.update!(llm_vendor: "openai")
    replacement = Collavre::AgentGateway.create!(
      owner: @owner, name: "Replacement", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    agent = @agent
    client = Object.new
    client.define_singleton_method(:provision_sync) { agent.update!(agent_gateway: replacement); {} }
    Collavre::CliProxy::Client.stub(:new, client) do
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id, workspace_id: @first.id)
    end
    assert_equal replacement.id, @agent.reload.agent_gateway_id
  end

  test "does nothing for a missing agent or missing or inactive gateway" do
    calls = 0
    counter = ->(**) { calls += 1 }

    Collavre::CliProxy::Client.stub(:new, counter) do
      Collavre::AgentProvisioningSyncJob.perform_now(0)
      @gateway.update_columns(active: false)
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
      @agent.update_columns(agent_gateway_id: nil)
      Collavre::AgentProvisioningSyncJob.perform_now(@agent.id)
    end

    assert_equal 0, calls
  end
end
