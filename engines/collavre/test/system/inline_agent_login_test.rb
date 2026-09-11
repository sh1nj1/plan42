require_relative "../application_system_test_case"

class InlineAgentLoginTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "inline-browser@example.com", password: SystemHelpers::PASSWORD,
      name: "Inline browser", email_verified_at: Time.current, locale: "en", notifications_enabled: false)
    gateway = Collavre::AgentGateway.create!(owner: @user, name: "Browser proxy", base_url: "https://proxy.example.com",
      admin_key: "admin-secret", completion_key: "completion-secret", identity_secret: "c" * 32, workspace_mode: :per_user)
    @agent = User.create!(name: "Browser Agent", email: "inline-browser@ai.local", password: SecureRandom.hex(24),
      system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @user.id, agent_gateway: gateway)
    @creative = Creative.create!(user: @user, description: "Inline browser test")
    @original = @creative.comments.create!(user: @user, content: "Please answer this request", skip_dispatch: true)
    @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @user)
    @task = Task.create!(name: "Browser login", agent: @agent, status: :done, creative: @creative, topic_id: @original.topic_id,
      trigger_event_name: "comment_created", trigger_event_payload: {
        "creative" => { "id" => @creative.id }, "topic" => { "id" => @original.topic_id },
        "comment" => { "id" => @original.id }, "workspace_user_id" => @user.id,
        "engine_login" => { "engine" => "claude", "workspace_id" => @workspace.id, "retryable" => true }
      })
    @reply = @creative.comments.create!(user: @agent, content: "Sign in to continue", task: @task, skip_dispatch: true)
    resize_window_to
    sign_in_via_ui(@user)
  end

  test "chat card submits a paste code privately and resumes the original request once" do
    submitted = nil
    resumed = []
    proxy = Object.new
    proxy.define_singleton_method(:engines) { { "data" => [ { "engine" => "claude", "flows" => [ "paste-code" ] } ] } }
    proxy.define_singleton_method(:create_auth_session) do |engine, **options|
      { "engine" => engine, "flow" => "paste-code", "sessionId" => "browser-session", "status" => "pending",
        "verificationUrl" => "https://claude.com/login", "expiresAt" => 10.minutes.from_now.iso8601 }
    end
    proxy.define_singleton_method(:submit_auth_session) do |engine, id, value|
      submitted = value
      { "engine" => engine, "flow" => "paste-code", "sessionId" => id, "status" => "authorized" }
    end
    Collavre::CliProxy::Client.stub(:new, proxy) do
      Collavre::AiAgentJob.stub(:perform_later, ->(*args) { resumed << args }) do
        visit collavre.creative_path(@creative, open_comments: true)
        assert_selector "#comments-popup", visible: :visible
        within("#inline_agent_login_#{@reply.id}") do
          click_button "Log in (paste-code)"
          assert_link "Open verification page", href: "https://claude.com/login"
          find('[data-role="secret"]').set("private-browser-code")
          find('[data-action="agent-connection#submit"]').click
          assert_text "Login complete. The original request has been queued again."
          assert_no_selector '[data-role="secret"]'
        end
        assert_equal "private-browser-code", submitted
        assert_equal 1, resumed.length
        assert_equal @original.id, resumed.first[2].dig("comment", "id")
        assert_not_includes @reply.reload.content, "private-browser-code"
        assert_not_includes @task.reload.trigger_event_payload.to_json, "private-browser-code"
      end
    end
  end
end
