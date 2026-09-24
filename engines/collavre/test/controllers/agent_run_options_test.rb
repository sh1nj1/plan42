# frozen_string_literal: true

require "test_helper"

class AgentRunOptionsControllersTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    sign_in_as @user, password: "password"
  end

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
      assert_select "button.agent-run-options-toggle[aria-controls='agent-run-options-panel']"
      assert_select "select[hidden][name='comment[agent_run_options][reasoning_effort]'] option[value='xhigh']"
      assert_select "input[name='comment[agent_run_options][model]']", count: 0
      assert_select "datalist#agent-run-options-models", count: 0
      assert_select "#agent-run-options-panel.common-popup ul[data-popup-list]"
      assert_select "#agent-run-options-panel input, #agent-run-options-panel select", count: 0
      assert_select ".agent-run-options-help", text: I18n.t("collavre.comments.agent_run_options.priority_help")
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
