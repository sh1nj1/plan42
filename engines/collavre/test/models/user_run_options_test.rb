# frozen_string_literal: true

require "test_helper"

class UserRunOptionsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @owner = users(:two)
    @gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Run options gateway",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
    @agent = Collavre::User.create!(
      name: "Run options agent",
      email: "run-options-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )
  end

  teardown { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

  test "reasoning effort must be a known level and blank means none" do
    @agent.reasoning_effort = " xhigh "
    assert @agent.valid?
    assert_equal "xhigh", @agent.reasoning_effort

    @agent.reasoning_effort = ""
    assert @agent.valid?
    assert_nil @agent.reasoning_effort

    @agent.reasoning_effort = "turbo"
    assert_not @agent.valid?
    assert @agent.errors.of_kind?(:reasoning_effort, :inclusion)
  end

  test "CLI defaults must be compatible on create and update" do
    { "claude_local" => "minimal", "codex_local" => "max", "unknown" => "high" }.each do |adapter, effort|
      @agent.assign_attributes(llm_model: "paperclip/#{adapter}", reasoning_effort: effort)
      assert_not @agent.save
      assert @agent.errors.of_kind?(:reasoning_effort, :inclusion)
      candidate = @agent.dup
      candidate.email = "invalid-#{adapter}@ai.local"
      assert_not candidate.save
    end
    @agent.reload.update!(llm_model: "paperclip/claude_local", reasoning_effort: "max")
  end

  test "normalized CLI vendors enforce model compatibility on create and update" do
    [ "CLI_PROXY", " cli_proxy ", " CLI_PROXY " ].each do |vendor|
      @agent.assign_attributes(llm_vendor: vendor, reasoning_effort: "max")
      assert_not @agent.save
      assert @agent.errors.of_kind?(:reasoning_effort, :inclusion)
      candidate = @agent.dup
      candidate.email = "normalized-invalid@ai.local"
      assert_not candidate.save
      @agent.reasoning_effort = "high"
      assert @agent.save
    end
  end

  test "padded models accept compatible defaults on create and update and reject incompatible ones" do
    @gateway.update!(identity_secret: "s" * 32)
    { "codex_local/gpt-5.4" => [ "minimal", "max" ], "claude_local/sonnet" => [ "max", "minimal" ] }.each do |model, (valid, invalid)|
      @agent.assign_attributes(llm_model: " \t paperclip/#{model} \n", reasoning_effort: valid)
      assert @agent.save, @agent.errors.full_messages.join(", ")
      candidate = @agent.dup
      candidate.email = "padded-#{model.split('/').first}@ai.local"
      assert candidate.save, candidate.errors.full_messages.join(", ")
      assert_not @agent.update(reasoning_effort: invalid)
      assert @agent.errors.of_kind?(:reasoning_effort, :inclusion)
      assert_equal valid, @agent.reload.reasoning_effort
    end
  end

  test "leaving CLI Proxy disables fast and syncs with or without a model change" do
    [ "paperclip/codex_local", "gpt-5" ].each do |model|
      @agent.update!(llm_vendor: " CLI_PROXY ", llm_model: "paperclip/codex_local", codex_fast_mode: true)
      assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ @agent.id ]) do
        @agent.update!(llm_vendor: "openai", llm_model: model)
      end
      assert_not @agent.effective_codex_fast_mode?
    end
  end

  test "returning to CLI Proxy syncs only when fast becomes enabled" do
    @agent.update!(llm_vendor: "openai", codex_fast_mode: true)
    assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ @agent.id ]) do
      @agent.update!(llm_vendor: "cli_proxy")
    end
    @agent.update!(llm_vendor: "openai", codex_fast_mode: false)
    assert_no_enqueued_jobs(only: Collavre::AgentProvisioningSyncJob) do
      @agent.update!(llm_vendor: "cli_proxy")
    end
  end

  test "changing to an old model removes published fast mode and syncs" do
    @agent.update!(codex_fast_mode: true)
    assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ @agent.id ]) do
      @agent.update!(llm_model: "paperclip/codex_local/gpt-5.3")
    end
    assert_not @agent.effective_codex_fast_mode?
  end

  test "effective fast mode needs codex_local" do
    assert_not @agent.effective_codex_fast_mode?

    @agent.codex_fast_mode = true
    assert @agent.effective_codex_fast_mode?

    @agent.llm_model = "paperclip/codex_custom/openai/gpt-5"
    assert_not @agent.effective_codex_fast_mode?
  end

  test "a change to the published fast setting enqueues a workspace sync" do
    assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ @agent.id ]) do
      @agent.update!(codex_fast_mode: true)
    end

    assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ @agent.id ]) do
      @agent.update!(llm_model: "paperclip/claude_local")
    end
  end

  test "changes that leave the published fast setting alone do not sync" do
    assert_no_enqueued_jobs(only: Collavre::AgentProvisioningSyncJob) do
      @agent.update!(llm_model: "paperclip/codex_local/gpt-5.5")
      @agent.update!(reasoning_effort: "high")
      @agent.update!(llm_model: "paperclip/claude_local", codex_fast_mode: true)
    end
  end

  test "a non-proxy agent never syncs" do
    agent = Collavre::User.create!(
      name: "Plain agent",
      email: "plain-run-options-agent@ai.local",
      password: SecureRandom.hex(24),
      llm_vendor: "openai",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id
    )

    assert_no_enqueued_jobs(only: Collavre::AgentProvisioningSyncJob) do
      agent.update!(codex_fast_mode: true)
    end
  end
end
