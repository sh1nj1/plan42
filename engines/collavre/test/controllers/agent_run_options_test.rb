# frozen_string_literal: true

require "test_helper"

class AgentRunOptionsControllersTest < ActionDispatch::IntegrationTest
  setup do
    @previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user = users(:one)
    @creative = creatives(:tshirt)
    sign_in_as @user, password: "password"
  end

  teardown { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

  def cli_proxy_agent(model: "paperclip/codex_local")
    gateway = Collavre::AgentGateway.create!(
      owner: @user, name: "Run options proxy", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    Collavre::User.create!(
      name: "Run options proxy agent", email: "run-options-proxy@ai.local", password: SecureRandom.hex(24),
      system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: model,
      created_by_id: @user.id, agent_gateway: gateway
    )
  end

  test "a new message keeps only the known run options" do
    post creative_comments_path(@creative), params: {
      comment: {
        content: "Run this deeper",
        agent_run_options: { reasoning_effort: " high ", model: "paperclip/claude_local/opus", extra: "dropped" }
      }
    }

    assert_response :success
    comment = Collavre::Comment.order(:id).last
    assert_equal "Run this deeper", comment.content
    assert_equal({ "reasoning_effort" => "high" }, comment.agent_run_options)
  end

  test "a message without run options stores none" do
    post creative_comments_path(@creative), params: {
      comment: { content: "Plain", agent_run_options: { reasoning_effort: "", model: "" } }
    }

    assert_nil Collavre::Comment.order(:id).last.agent_run_options
  end

  test "editing a message does not change the options it was sent with" do
    comment = @creative.comments.create!(content: "Sent", user: @user, agent_run_options: { "reasoning_effort" => "low" })

    patch creative_comment_path(@creative, comment), params: {
      comment: { content: "Edited", agent_run_options: { reasoning_effort: "max" } }
    }

    assert_equal({ "reasoning_effort" => "low" }, comment.reload.agent_run_options)
  end

  test "a comment shows the run options it carries" do
    @creative.comments.create!(
      content: "Answer", user: @user,
      agent_run_options: { "model" => "paperclip/claude_local/opus", "reasoning_effort" => "max" }
    )

    get creative_comments_path(@creative)

    assert_response :success
    assert_select ".agent-run-options-label", text: /claude_local\/opus · max/
  end

  test "the chat composer offers run options inside the comment form" do
    Collavre::LlmModel.create!(llm_vendor: "cli_proxy", name: "paperclip/claude_local/opus")

    get creatives_path(id: creatives(:root_parent))

    assert_response :success
    assert_select "form#new-comment-form[data-controller~='comments--run-options']" do
      assert_select "button.agent-run-options-toggle[aria-controls='agent-run-options-panel']" do
        assert_select "[aria-label=?]", I18n.t("collavre.comments.agent_run_options.button_title")
        assert_select "svg.thinking-icon[aria-hidden='true'][focusable='false']"
      end
      assert_select "select[hidden][name='comment[agent_run_options][reasoning_effort]'] option[value='xhigh']"
      assert_select "input[name='comment[agent_run_options][model]']", count: 0
      assert_select "datalist#agent-run-options-models", count: 0
      assert_select "#agent-run-options-panel.common-popup ul[data-popup-list]"
      assert_select "#agent-run-options-panel input, #agent-run-options-panel select", count: 0
      assert_select ".agent-run-options-help", text: I18n.t("collavre.comments.agent_run_options.priority_help")
    end
  end

  test "composer explains engine exclusive efforts in both languages" do
    %i[en ko].each do |locale|
      @user.update!(locale: locale)
      get creatives_path(id: creatives(:root_parent))
      assert_response :success
      %w[none minimal max].each do |effort|
        key = "collavre.comments.agent_run_options"
        assert_select "option[value=?][data-warning=?]", effort, I18n.t("#{key}.warnings.#{effort}", locale: locale),
                      text: I18n.t("#{key}.labels.#{effort}", locale: locale)
      end
      assert_select "[data-comments--run-options-target='warning'][role='status'][hidden]"
      %w[low medium high xhigh].each do |effort|
        assert_select "option[value=?][data-warning='']", effort, text: effort
      end
    end
  end

  test "create_ai stores the thinking level and fast mode" do
    gateway = Collavre::AgentGateway.create!(
      owner: @user, name: "Create proxy", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )

    post create_ai_users_path, params: {
      ai_id: "run-options-created", name: "Created", system_prompt: "Help",
      llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", agent_gateway_id: gateway.id,
      reasoning_effort: "xhigh", codex_fast_mode: "1"
    }

    agent = Collavre::User.find_by!(email: "run-options-created@ai.local")
    assert_equal "xhigh", agent.reasoning_effort
    assert agent.codex_fast_mode?
  end

  test "update_ai changes the thinking level and fast mode, and edit renders them" do
    agent = cli_proxy_agent

    patch update_ai_user_path(agent), params: { user: { reasoning_effort: "minimal", codex_fast_mode: "1" } }
    agent.reload
    assert_equal "minimal", agent.reasoning_effort
    assert agent.codex_fast_mode?

    get edit_ai_user_path(agent)
    assert_response :success
    assert_select "select[name='user[reasoning_effort]'][data-efforts] option[selected][value='minimal']"
    assert_select "input[type='checkbox'][name='user[codex_fast_mode]'][checked]"
  end

  test "update_ai rejects incompatible effort for a normalized CLI vendor" do
    agent = cli_proxy_agent
    patch update_ai_user_path(agent), params: {
      user: { llm_vendor: " CLI_PROXY ", reasoning_effort: "max" }
    }
    assert_response :unprocessable_entity
    assert_nil agent.reload.reasoning_effort
    assert_equal "cli_proxy", agent.llm_vendor
  end

  test "update_ai accepts padded models with compatible efforts and rejects incompatible efforts" do
    agent = cli_proxy_agent
    { "codex_local/gpt-5.4" => [ "minimal", "max" ], "claude_local/sonnet" => [ "max", "minimal" ] }.each do |model, (valid, invalid)|
      patch update_ai_user_path(agent), params: {
        user: { llm_model: "  paperclip/#{model}  ", reasoning_effort: valid }
      }
      assert_response :redirect
      assert_equal valid, agent.reload.reasoning_effort
      assert_equal valid, Collavre::CliProxy::RunOptions.resolve(agent: agent).reasoning_effort

      patch update_ai_user_path(agent), params: { user: { reasoning_effort: invalid } }
      assert_response :unprocessable_entity
      assert_equal valid, agent.reload.reasoning_effort
    end
  end

  test "update_ai retains the workspace until Fast off sync then detaches the gateway" do
    agent = cli_proxy_agent
    agent.update_columns(codex_fast_mode: true)
    gateway = agent.agent_gateway
    workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: nil)
    token = workspace.manifest_token
    callback_token = workspace.callback_token

    assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ agent.id ]) do
      patch update_ai_user_path(agent), params: {
        user: { llm_vendor: "openai", llm_model: "gpt-5", agent_gateway_id: "" }
      }
      assert_response :redirect
    end
    assert_equal gateway.id, agent.reload.agent_gateway_id
    assert_equal token, workspace.reload.manifest_token
    assert_equal callback_token, workspace.callback_token
    get agent_provision_manifest_path(agent_id: agent.id, token: token)
    assert_response :success
    refute response.parsed_body.key?("runtime")

    client = Minitest::Mock.new
    client.expect :provision_sync, {}
    factory = lambda do |gateway:, workspace:|
      assert_equal agent.agent_gateway_id, gateway.id
      assert_equal token, workspace.manifest_token
      client
    end
    Collavre::CliProxy::Client.stub :new, factory do
      Collavre::AgentProvisioningSyncJob.perform_now(agent.id)
    end
    client.verify
    assert_nil agent.reload.agent_gateway_id
    refute Collavre::AgentWorkspace.exists?(workspace.id)
    assert Doorkeeper::AccessToken.by_token(callback_token).revoked?
    get agent_provision_manifest_path(agent_id: agent.id, token: token)
    assert_response :not_found
    assert gateway.update(completion_key: nil)
    assert gateway.destroy
  end

  test "leaving CLI Proxy with Fast already off still schedules cleanup" do
    agent = cli_proxy_agent
    assert_enqueued_with(job: Collavre::AgentProvisioningSyncJob, args: [ agent.id ]) do
      patch update_ai_user_path(agent), params: { user: { llm_vendor: "openai", llm_model: "gpt-5" } }
      assert_response :redirect
    end
  end

  test "non CLI updates cannot assign or replace a gateway through a hidden field" do
    agent = cli_proxy_agent
    original_gateway = agent.agent_gateway
    foreign_gateway = Collavre::AgentGateway.create!(
      owner: users(:two), name: "Foreign proxy", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    [ { llm_vendor: "openai", agent_gateway_id: foreign_gateway.id },
      { name: "Still retained", agent_gateway_id: foreign_gateway.id } ].each do |attributes|
      patch update_ai_user_path(agent), params: { user: attributes }
      assert_response :redirect
      assert_equal original_gateway.id, agent.reload.agent_gateway_id
    end

    patch update_ai_user_path(agent), params: {
      user: { llm_vendor: "cli_proxy", agent_gateway_id: foreign_gateway.id }
    }
    assert_response :unprocessable_entity
    assert_equal original_gateway.id, agent.reload.agent_gateway_id
    assert_equal "openai", agent.llm_vendor
  end

  test "agent settings explain thinking precedence and allow clearing the default" do
    agent = cli_proxy_agent
    agent.update!(reasoning_effort: "high")

    %i[en ko].each do |locale|
      @user.update!(locale: locale)
      get edit_ai_user_path(agent)
      assert_response :success
      assert_select "label[for='user_reasoning_effort']", I18n.t("collavre.users.new_ai.reasoning_effort_label", locale: locale)
      assert_select "select[name='user[reasoning_effort]'] option[value='']", I18n.t("collavre.users.new_ai.reasoning_effort_blank", locale: locale)
      assert_select "small", text: I18n.t("collavre.users.new_ai.reasoning_effort_help", locale: locale)
    end

    patch update_ai_user_path(agent), params: { user: { reasoning_effort: "" } }
    assert_response :redirect
    assert_predicate agent.reload.reasoning_effort, :blank?
  end

  test "the connection screen knows whether fast mode is expected" do
    agent = cli_proxy_agent
    agent.update_columns(codex_fast_mode: true)

    get agent_connection_user_path(agent)

    assert_response :success
    assert_select "[data-agent-connection-fast-mode-expected-value='true']"
    assert_select "[data-agent-connection-fast-mode-pending-value]"
  end
end
