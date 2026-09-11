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
    Collavre::CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback)
    Collavre::CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
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
    proxy.define_singleton_method(:auth_session) do |engine, id|
      { "engine" => engine, "flow" => "paste-code", "sessionId" => id, "status" => "pending",
        "verificationUrl" => "https://claude.com/login", "expiresAt" => 10.minutes.from_now.iso8601 }
    end
    proxy.define_singleton_method(:submit_auth_session) do |engine, id, value|
      submitted = value
      { "engine" => engine, "flow" => "paste-code", "sessionId" => id, "status" => "authorized" }
    end
    Collavre::CliProxy::Client.stub(:new, proxy) do
      Collavre::InlineAgentReplayJob.stub(:perform_later, ->(*args) { resumed << args; Collavre::InlineAgentReplayJob.new.tap { |job| job.successfully_enqueued = true } }) do
        visit collavre.creative_path(@creative, open_comments: true)
        assert_selector "#comments-popup", visible: :visible
        within("#inline_agent_login_#{@reply.id}") do
          click_button "Log in (paste-code)"
          assert_link "Open verification page", href: "https://claude.com/login"
          find('[data-role="secret"]').set("private-browser-code")
          page.driver.browser.execute_async_script(<<~JS)
            const done = arguments[0];
            const popup = document.querySelector('#comments-popup');
            const controller = window.Stimulus.getControllerForElementAndIdentifier(popup, 'comments--list');
            const fetchComments = controller.fetchComments.bind(controller);
            controller.fetchComments = (...args) => fetchComments(...args).then(html => {
              controller.fetchComments = fetchComments;
              setTimeout(done, 0);
              return html;
            });
            controller.loadInitialComments();
          JS
          assert_selector '[data-role="secret"]', visible: true
          assert_equal "private-browser-code", find('[data-role="secret"]').value
          find('[data-action="agent-connection#submit"]').click
          assert_text "Login complete. The original request has been queued again."
          assert_no_selector '[data-role="secret"]'
        end
        assert_equal "private-browser-code", submitted
        assert_equal 1, resumed.length
        assert_equal [ @reply.id, @user.id, @task.id ], resumed.first
        assert_not_includes @reply.reload.content, "private-browser-code"
        assert_not_includes @task.reload.trigger_event_payload.to_json, "private-browser-code"
      end
    end
  end
  test "device code login polls from the chat card and resumes without a secret submission" do
    payload = @task.trigger_event_payload
    @task.update!(trigger_event_payload: payload.merge("engine_login" => payload["engine_login"].merge("engine" => "codex")))
    resumed = []
    authorized = false
    proxy = Object.new
    proxy.define_singleton_method(:engines) { { "data" => [ { "engine" => "codex", "flows" => [ "device-code" ] } ] } }
    proxy.define_singleton_method(:create_auth_session) do |engine, **options|
      { "engine" => engine, "flow" => "device-code", "sessionId" => "device-session", "status" => "pending",
        "verificationUrl" => "https://auth.openai.com/codex/device", "userCode" => "ABCD-EFGH",
        "expiresAt" => 10.minutes.from_now.iso8601 }
    end
    proxy.define_singleton_method(:auth_session) do |engine, id|
      { "engine" => engine, "flow" => "device-code", "sessionId" => id, "status" => authorized ? "authorized" : "pending",
        "verificationUrl" => "https://auth.openai.com/codex/device", "userCode" => "ABCD-EFGH", "expiresAt" => 10.minutes.from_now.iso8601 }
    end
    Collavre::CliProxy::Client.stub(:new, proxy) do
      Collavre::InlineAgentReplayJob.stub(:perform_later, ->(*args) { resumed << args; Collavre::InlineAgentReplayJob.new.tap { |job| job.successfully_enqueued = true } }) do
        visit collavre.creative_path(@creative, open_comments: true)
        within("#inline_agent_login_#{@reply.id}") do
          click_button "Log in (device-code)"
          assert_text "ABCD-EFGH"
          authorized = true
          assert_no_selector '[data-role="secret"]'
          assert_text "Login complete. The original request has been queued again.", wait: 8
        end
        assert_equal 1, resumed.length
        assert_not_includes @task.reload.trigger_event_payload.to_json, "ABCD-EFGH"
      end
    end
  end
end
