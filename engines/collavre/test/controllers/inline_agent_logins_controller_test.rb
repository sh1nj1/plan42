require "test_helper"

class InlineAgentLoginsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @owner = users(:two)
    @requester = users(:three)
    @gateway = Collavre::AgentGateway.create!(owner: @owner, name: "Inline proxy", base_url: "https://proxy.example.com",
      admin_key: "admin-secret", completion_key: "completion-secret", identity_secret: "c" * 32, workspace_mode: :per_user)
    @agent = Collavre::User.create!(name: "Inline Agent", email: "inline@ai.local", password: SecureRandom.hex(24),
      system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @owner.id, agent_gateway: @gateway)
    Collavre::Contact.ensure(user: @requester, contact_user: @agent)
    @creative = Collavre::Creative.create!(user: @requester, description: "Inline test")
    Collavre::CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback)
    Collavre::CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
    @original = @creative.comments.create!(user: @requester, content: "Hello", skip_dispatch: true)
    @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @requester)
    @task = Collavre::Task.create!(name: "Login turn", agent: @agent, status: :done, creative: @creative,
      topic_id: @original.topic_id, trigger_event_name: "comment_created", trigger_event_payload: {
        "creative" => { "id" => @creative.id }, "topic" => { "id" => @original.topic_id },
        "comment" => { "id" => @original.id }, "workspace_user_id" => @requester.id,
        "engine_login" => { "engine" => "codex", "workspace_id" => @workspace.id, "retryable" => true }
      })
    @reply = @creative.comments.create!(user: @agent, content: "Login required", task: @task, topic_id: @original.topic_id, skip_dispatch: true)
    sign_in_as(@requester, password: "password")
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "recording a login requirement broadcasts the card only once through the commit callback" do
    error = Collavre::CliProxy::EngineUnauthenticatedError.new(engine: "codex", workspace: @workspace)
    broadcasts = []
    clear_enqueued_jobs

    ActionCable.server.stub(:broadcast, ->(_stream, content) { broadcasts << content }) do
      assert_enqueued_jobs 1, only: Turbo::Streams::ActionBroadcastJob do
        Collavre::CliProxy::InlineLogin.record!(@task, @reply, error, content: "", retryable: true)
      end
      assert_empty broadcasts, "Do not show the card before its queued replacement arrives"
      perform_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob)
    end

    assert_equal 1, broadcasts.size
    stream = Nokogiri::HTML.fragment(broadcasts.first)
    assert_equal "replace", stream.at_css("turbo-stream")["action"]
    assert_equal "comment_#{@reply.id}", stream.at_css("turbo-stream")["target"]
    assert stream.at_css("turbo-frame#inline_agent_login_#{@reply.id}")
    assert_equal "false", stream.at_css(".comment-item")["data-streaming"]
  end

  test "requester gets inline controls without secrets" do
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :success
    assert_select "turbo-frame#inline_agent_login_#{@reply.id} [data-controller=agent-connection]"
    assert_select "[data-agent-connection-resume-url-value]"
    %w[admin-secret completion-secret].each { |secret| assert_not_includes response.body, secret }
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "other users cannot authenticate or retry the requester's workspace" do
    @creative.update!(user: @owner)
    sign_in_as(@owner, password: "password")
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :success
    assert_select "[data-controller=agent-connection]", count: 0
    post inline_agent_login_sessions_path(comment_id: @reply.id), params: { flow: "api-key" }, as: :json
    assert_response :forbidden
    post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    assert_response :forbidden
  end

  test "shared connection requires the owner and preserves the triggering principal on retry" do
    @gateway.update!(workspace_mode: :shared)
    @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @requester)
    set_data("workspace_id" => @workspace.id)
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :success
    assert_select "[data-controller=agent-connection]", count: 0
    @creative.update!(user: @owner)
    sign_in_as(@owner, password: "password")
    get inline_agent_login_path(comment_id: @reply.id)
    assert_select "[data-controller=agent-connection]"
    set_data("authorized" => true, "session_user_id" => @owner.id)
    assert_enqueued_with(job: Collavre::AiAgentJob, args: [ @agent.id, "comment_created", @task.reload.trigger_event_payload.except("engine_login") ]) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
  end

  test "inaccessible, deleted, moved, private and stale requests fail closed" do
    @original.update!(private: true)
    @creative.update!(user: @owner)
    sign_in_as(@owner, password: "password")
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :not_found
    sign_in_as(@requester, password: "password")
    @gateway.update!(active: false)
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :not_found
  end

  test "session uses recorded engine and workspace and keeps credentials out of persisted data" do
    created = { "sessionId" => "session-one", "engine" => "codex", "flow" => "api-key", "status" => "pending" }
    fake = Minitest::Mock.new
    fake.expect(:create_auth_session, created) do |engine, flow:, provisioning_url:|
      engine == "codex" && flow == "api-key" && provisioning_url.include?(@workspace.manifest_token)
    end
    fake.expect(:submit_auth_session, created.merge("status" => "authorized"), [ "codex", "session-one", "private-login-secret" ])
    Collavre::CliProxy::Client.stub(:new, ->(gateway:, workspace:) { assert_equal @workspace, workspace; fake }) do
      post inline_agent_login_sessions_path(comment_id: @reply.id), params: { engine: "claude", flow: "api-key" }, as: :json
      assert_response :created
      post inline_agent_login_session_path(comment_id: @reply.id, session_id: "session-one"), params: { auth_secret: "private-login-secret" }, as: :json
      assert_response :success
    end
    fake.verify
    assert @task.reload.trigger_event_payload.dig("engine_login", "authorized")
    assert_not_includes @task.trigger_event_payload.to_json, "private-login-secret"
    assert_not_includes @reply.reload.content, "private-login-secret"
  end

  test "polling device login records authorization and cancellation revokes it" do
    set_data("session_id" => "device-session", "session_user_id" => @requester.id)
    fake = Minitest::Mock.new
    fake.expect(:auth_session, { "status" => "authorized" }, [ "codex", "device-session" ])
    fake.expect(:cancel_auth_session, { "status" => "cancelled" }, [ "codex", "device-session" ])
    Collavre::CliProxy::Client.stub(:new, fake) do
      get inline_agent_login_session_path(comment_id: @reply.id, session_id: "device-session"), as: :json
      assert_response :success
      assert @task.reload.trigger_event_payload.dig("engine_login", "authorized")
      delete inline_agent_login_session_path(comment_id: @reply.id, session_id: "device-session"), as: :json
      assert_response :success
      assert_not @task.reload.trigger_event_payload.dig("engine_login", "authorized")
    end
    fake.verify
  end

  test "session identifiers from another card or a superseded attempt are rejected before proxy access" do
    set_data("session_id" => "new-session", "session_user_id" => @requester.id)
    get inline_agent_login_session_path(comment_id: @reply.id, session_id: "old-session"), as: :json
    assert_response :conflict
    assert_equal "session_superseded", response.parsed_body.dig("error", "code")
  end

  test "resume requires server authorization and enqueues the original request only once" do
    assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), params: { authorized: true }, as: :json
    end
    assert_response :conflict
    set_data("authorized" => true, "session_user_id" => @requester.id)
    assert_enqueued_jobs 1, only: Collavre::AiAgentJob do
      2.times { post inline_agent_login_resume_path(comment_id: @reply.id), as: :json; assert_response :success }
    end
    assert @task.reload.trigger_event_payload.dig("engine_login", "resumed")
  end

  test "partial and cancelled turns cannot be automatically replayed" do
    set_data("authorized" => true, "session_user_id" => @requester.id, "retryable" => false)
    get inline_agent_login_path(comment_id: @reply.id)
    assert_select "[data-agent-connection-resume-url-value]", count: 0
    assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :conflict
    set_data("retryable" => true)
    @task.update!(status: :cancelled)
    post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    assert_response :conflict
  end

  test "status restores a pending session only to its initiating user" do
    set_data("session_id" => "pending", "session_user_id" => @requester.id)
    fake = Minitest::Mock.new
    fake.expect(:engines, { "data" => [ { "engine" => "codex", "flow" => "api-key", "flows" => [ "api-key", "custom" ], "base_url_flows" => [ "custom" ] } ] })
    fake.expect(:auth_session, { "status" => "pending", "userCode" => "PRIVATE-CODE" }, [ "codex", "pending" ])
    Collavre::CliProxy::Client.stub(:new, fake) { get inline_agent_login_status_path(comment_id: @reply.id), as: :json }
    assert_response :success
    assert_equal "PRIVATE-CODE", response.parsed_body.dig("session", "userCode")
    assert_equal [ "api-key" ], response.parsed_body["engines"].first["flows"]
    assert_not_includes @task.reload.trigger_event_payload.to_json, "PRIVATE-CODE"
    fake.verify
  end

  test "expired session recovery leaves an error and login controls" do
    set_data("session_id" => "expired", "session_user_id" => @requester.id)
    fake = Object.new
    fake.define_singleton_method(:engines) { { "data" => [ { "engine" => "codex", "flow" => "api-key" } ] } }
    fake.define_singleton_method(:auth_session) { |*| raise Collavre::CliProxy::Client::Error.new("Expired", status: 404, code: "unknown_session") }
    Collavre::CliProxy::Client.stub(:new, fake) { get inline_agent_login_status_path(comment_id: @reply.id), as: :json }
    assert_response :success
    assert_equal "failed", response.parsed_body.dig("session", "status")
    assert_equal "Expired", response.parsed_body.dig("session", "error", "message")
  end

  test "scheduler rejection rolls back the replay claim" do
    set_data("authorized" => true, "session_user_id" => @requester.id)
    fake = Minitest::Mock.new
    fake.expect(:schedule, [ { timing: :rejected } ], [ [ @agent ] ])
    Collavre::Orchestration::Scheduler.stub(:new, fake) do
      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      end
    end
    assert_response :conflict
    assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
    fake.verify
  end

  test "removed agent access prevents replay even after login succeeds" do
    set_data("authorized" => true, "session_user_id" => @requester.id)
    Collavre::CreativeShare.where(creative: @creative, user: @agent).destroy_all
    Collavre::CreativeSharesCache.where(creative: @creative, user: @agent).delete_all
    assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :conflict
    assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
  end

  test "deleted or moved source messages cannot be replayed" do
    @original.update!(topic_id: @creative.topics.create!(name: "Moved", user: @requester).id)
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :not_found
    @original.destroy!
    post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    assert_response :not_found
  end

  private

  def set_data(values)
    payload = @task.reload.trigger_event_payload
    @task.update!(trigger_event_payload: payload.merge("engine_login" => payload.fetch("engine_login").merge(values)))
  end
end
