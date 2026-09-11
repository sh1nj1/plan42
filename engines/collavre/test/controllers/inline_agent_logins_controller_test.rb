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

  [ true, false ].each do |finish_before_broadcast|
    test "login card is broadcast once when task finishes #{finish_before_broadcast ? 'before' : 'after'} the queued replacement" do
      @task.update!(status: :running, trigger_event_payload: @task.trigger_event_payload.except("engine_login"))
      error = Collavre::CliProxy::EngineUnauthenticatedError.new(engine: "codex", workspace: @workspace)
      broadcasts = []
      clear_enqueued_jobs

      ActionCable.server.stub(:broadcast, ->(_stream, content) { broadcasts << content }) do
        assert_enqueued_jobs 1, only: Turbo::Streams::ActionBroadcastJob do
          Collavre::CliProxy::InlineLogin.record!(@task, @reply, error, content: "", retryable: true)
        end
        @task.done! if finish_before_broadcast
        assert_empty broadcasts, "Do not show the card before its queued replacement arrives"
        perform_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob)
        @task.done! unless finish_before_broadcast
        @task.fire_completion_callbacks_after_external_claim
        perform_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob)
      end

      assert_equal 1, broadcasts.size
      stream = Nokogiri::HTML.fragment(broadcasts.first)
      assert_equal "replace", stream.at_css("turbo-stream")["action"]
      assert_equal "comment_#{@reply.id}", stream.at_css("turbo-stream")["target"]
      assert stream.at_css("turbo-frame#inline_agent_login_#{@reply.id}")
      assert_equal "false", stream.at_css(".comment-item")["data-streaming"]
      assert_nil stream.at_css(".comment-stop-btn"), "Login cards must not retain a stop button even before the task finishes"
    end
  end

  test "failed card persistence rolls back login metadata and handoff failure together" do
    @task.update!(status: :running, trigger_event_payload: @task.trigger_event_payload.except("engine_login"))
    payload = @task.trigger_event_payload.deep_dup
    content = @reply.content
    error = Collavre::CliProxy::EngineUnauthenticatedError.new(engine: "codex", workspace: @workspace)
    clear_enqueued_jobs

    @reply.stub(:update!, ->(*) { raise ActiveRecord::RecordInvalid.new(@reply) }) do
      assert_no_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob) do
        assert_raises(ActiveRecord::RecordInvalid) do
          Collavre::CliProxy::InlineLogin.record!(@task, @reply, error, content: "", retryable: true)
        end
      end
    end

    assert_equal payload, @task.reload.trigger_event_payload
    assert_equal content, @reply.reload.content
    assert @task.running?
  end

  test "ordinary replies still replace the comment to remove the stop button when the task finishes" do
    @task.update!(status: :running, trigger_event_payload: @task.trigger_event_payload.except("engine_login"))
    broadcasts = []
    clear_enqueued_jobs

    ActionCable.server.stub(:broadcast, ->(_stream, content) { broadcasts << content }) do
      @reply.broadcast_replace_to([ @creative, :comments ], partial: "collavre/comments/comment")
      assert Nokogiri::HTML.fragment(broadcasts.last).at_css(".comment-stop-btn")
      broadcasts.clear
      @task.done!
    end

    assert_equal 1, broadcasts.size
    stream = Nokogiri::HTML.fragment(broadcasts.first)
    assert_equal "comment_#{@reply.id}", stream.at_css("turbo-stream")["target"]
    assert_nil stream.at_css(".comment-stop-btn")
    assert_nil stream.at_css("turbo-frame#inline_agent_login_#{@reply.id}")
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
    expected = @task.reload.trigger_event_payload.except("engine_login").merge(
      "comment" => @original.dispatch_payload[:comment].deep_stringify_keys, "chat" => { "content" => @original.content }
    )
    assert_enqueued_with(job: Collavre::InlineAgentReplayJob, args: [ @reply.id, @owner.id, @task.id ]) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
    assert_equal [ expected.merge("inline_login_task_id" => @task.id) ], execute_replay_payloads
  end

  [ :shared, :per_user ].each do |mode|
    [ :absent, :explicit, :nil ].each do |principal|
      test "#{mode} replay preserves #{principal} requester through provider dispatch" do
        @gateway.update!(workspace_mode: mode)
        @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @requester)
        @creative.update!(user: @owner) if mode == :shared
        manager = mode == :shared ? @owner : @requester
        sign_in_as(manager, password: "password")
        payload = @task.reload.trigger_event_payload.except("workspace_user_id")
        payload["workspace_user_id"] = principal == :explicit ? @owner.id : nil unless principal == :absent
        @task.update!(trigger_event_payload: payload)
        set_data("workspace_id" => @workspace.id, "authorized" => true, "session_user_id" => manager.id)
        clear_enqueued_jobs
        post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
        assert_response :success

        expected = { absent: @requester, explicit: @owner, nil: nil }.fetch(principal)
        principals = []
        client = Object.new
        client.define_singleton_method(:chat) { |*, **, &block| block.call("Replay response") }
        client.define_singleton_method(:last_handoff_failed?) { false }
        client.define_singleton_method(:handed_off?) { true }
        factory = lambda do |**options|
          principals << [ options[:context][:workspace_user], Collavre::Current.agent_turn[:user] ]
          client
        end
        Collavre::AiClient.stub(:new, factory) do
          perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
        end

        assert_equal [ [ expected, expected ] ], principals
        assert @creative.comments.exists?(content: "Replay response")
        assert @task.reload.trigger_event_payload.dig("engine_login", "replay_completed")
      end
    end
  end

  test "inaccessible, deleted, moved, private and stale requests fail closed" do
    @original.update!(private: true)
    @creative.update!(user: @owner)
    sign_in_as(@owner, password: "password")
    get inline_agent_login_status_path(comment_id: @reply.id)
    assert_response :not_found
    sign_in_as(@requester, password: "password")
    @gateway.update!(active: false)
    get inline_agent_login_status_path(comment_id: @reply.id)
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

  %w[pending authorized].each do |old_status|
    test "late #{old_status} session start cannot replace a newer initiated session" do
      second = open_session
      second.post session_path, params: { email: @requester.email, password: "password" }
      second.assert_response :redirect
      starts = 0
      proxy = Object.new
      handler = ->(*) do
        starts += 1
        if starts == 1
          second.post inline_agent_login_sessions_path(comment_id: @reply.id), params: { flow: "device-code" }, as: :json
          second.assert_response :created
          { "sessionId" => "older-session", "status" => old_status }
        else
          { "sessionId" => "newer-session", "status" => "pending" }
        end
      end
      proxy.define_singleton_method(:create_auth_session) { |*args| handler.call(*args) }
      proxy.define_singleton_method(:auth_session) do |_engine, id|
        raise "Wrong session polled" unless id == "newer-session"
        { "sessionId" => id, "status" => "authorized" }
      end
      Collavre::CliProxy::Client.stub(:new, proxy) do
        post inline_agent_login_sessions_path(comment_id: @reply.id), params: { flow: "api-key" }, as: :json
        assert_response :conflict
        assert_equal "session_superseded", response.parsed_body.dig("error", "code")
        state = @task.reload.trigger_event_payload.fetch("engine_login")
        assert_equal "newer-session", state["session_id"]
        assert_equal false, state["authorized"]
        get inline_agent_login_session_path(comment_id: @reply.id, session_id: "newer-session"), as: :json
        assert_response :success
        assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "authorized")
      end
    end
  end

  [ :poll, :submit, :cancel, :status ].each do |operation|
    test "new session start invalidates an in-flight #{operation} response" do
      set_data("session_id" => "authorized-session", "session_user_id" => @requester.id)
      proxy = Object.new
      proxy.define_singleton_method(:engines) { { "data" => [] } }
      handler = ->(*) do
        login = Collavre::CliProxy::InlineLogin.new(@reply.reload, @requester)
        login.begin_session!
        { "sessionId" => "authorized-session", "status" => "authorized" }
      end
      method = { poll: :auth_session, submit: :submit_auth_session, cancel: :cancel_auth_session, status: :auth_session }.fetch(operation)
      proxy.define_singleton_method(method) { |*args| handler.call(*args) }
      Collavre::CliProxy::Client.stub(:new, proxy) { request_login_session(operation) }
      assert_response(operation.in?([ :status, :cancel ]) ? :success : :conflict)
      state = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_nil state["session_id"]
      assert_equal false, state["authorized"]
      assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
        post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      end
      assert_response :conflict
      assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    end
  end

  test "failed session start keeps old authorization revoked and permits a fresh attempt" do
    set_data("session_id" => "authorized-session", "session_user_id" => @requester.id, "authorized" => true)
    proxy = Object.new
    proxy.define_singleton_method(:create_auth_session) do |*|
      raise Collavre::CliProxy::Client::Error.new("Unavailable", status: 502, code: "proxy_unreachable")
    end
    Collavre::CliProxy::Client.stub(:new, proxy) { request_login_session(:create) }
    assert_response :bad_gateway
    state = @task.reload.trigger_event_payload.fetch("engine_login")
    assert_nil state["session_id"]
    assert_equal false, state["authorized"]
    proxy.define_singleton_method(:create_auth_session) { |*| { "sessionId" => "fresh-session", "status" => "pending" } }
    Collavre::CliProxy::Client.stub(:new, proxy) { request_login_session(:create) }
    assert_response :created
    assert_equal "fresh-session", @task.reload.trigger_event_payload.dig("engine_login", "session_id")
  end

  [ false, true ].each do |proxy_failure|
    test "cancel invalidates in-flight authorization before proxy IO even when DELETE fails #{proxy_failure}" do
      set_data("session_id" => "device-session", "session_user_id" => @requester.id)
      stale_login = Collavre::CliProxy::InlineLogin.new(@reply.reload, @requester)
      proxy = Object.new
      handler = ->(*) do
        error = assert_raises(Collavre::CliProxy::Client::Error) do
          stale_login.observe_session!({ "status" => "authorized" }, "device-session")
        end
        assert_equal "session_superseded", error.code
        error = assert_raises(Collavre::CliProxy::Client::Error) { stale_login.resume! }
        assert_equal "not_authorized", error.code
        state = @task.reload.trigger_event_payload.fetch("engine_login")
        assert_nil state["session_id"]
        assert_equal false, state["authorized"]
        raise Collavre::CliProxy::Client::Error.new("Unavailable", status: 502, code: "proxy_unreachable") if proxy_failure

        { "status" => "cancelled" }
      end
      proxy.define_singleton_method(:cancel_auth_session) { |*args| handler.call(*args) }
      assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
        Collavre::CliProxy::Client.stub(:new, proxy) do
          delete inline_agent_login_session_path(comment_id: @reply.id, session_id: "device-session"), as: :json
        end
      end
      assert_response(proxy_failure ? :bad_gateway : :success)
    end
  end

  test "a slow cancellation response preserves a newer successful login" do
    set_data("session_id" => "device-session", "session_user_id" => @requester.id)
    proxy = Object.new
    handler = ->(*) do
      login = Collavre::CliProxy::InlineLogin.new(@reply.reload, @requester)
      attempt = login.begin_session!
      login.remember_session!({ "sessionId" => "new-session", "status" => "authorized" }, attempt: attempt)
      { "status" => "cancelled" }
    end
    proxy.define_singleton_method(:cancel_auth_session) { |*args| handler.call(*args) }
    Collavre::CliProxy::Client.stub(:new, proxy) do
      delete inline_agent_login_session_path(comment_id: @reply.id, session_id: "device-session"), as: :json
    end
    assert_response :success
    state = @task.reload.trigger_event_payload.fetch("engine_login")
    assert_equal "new-session", state["session_id"]
    assert_equal true, state["authorized"]
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

  [ :create, :poll, :submit, :cancel ].each do |operation|
    test "claimed replay rejects #{operation} before contacting the proxy" do
      set_data("session_id" => "authorized-session")
      queue_delayed_replay
      before = @task.reload.trigger_event_payload.deep_dup
      Collavre::CliProxy::Client.stub(:new, ->(*) { flunk "claimed replay must not mutate proxy sessions" }) do
        request_login_session(operation)
      end
      assert_response :conflict
      assert_equal "already_resumed", response.parsed_body.dig("error", "code")
      assert_equal before, @task.reload.trigger_event_payload
      assert_equal 1, execute_replay_payloads.size
    end
  end

  test "claimed replay status stays readable without polling its old session" do
    set_data("session_id" => "authorized-session")
    queue_delayed_replay
    proxy = Minitest::Mock.new
    proxy.expect(:engines, { "data" => [] })
    Collavre::CliProxy::Client.stub(:new, proxy) do
      get inline_agent_login_status_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
    assert_equal true, response.parsed_body["resumed"]
    assert_equal true, response.parsed_body["authorized"]
    assert_nil response.parsed_body["session"]
    proxy.verify
  end

  [ :create, :poll, :submit, :status ].each do |operation|
    test "late #{operation} response cannot overwrite a committed replay claim" do
      set_data("session_id" => "authorized-session", "session_user_id" => @requester.id)
      proxy = Object.new
      method = { create: :create_auth_session, poll: :auth_session, submit: :submit_auth_session,
                 cancel: :cancel_auth_session, status: :auth_session }.fetch(operation)
      proxy.define_singleton_method(:engines) { { "data" => [] } }
      handler = ->(*) do
        set_data("authorized" => true, "resumed" => true)
        { "sessionId" => "late-session", "status" => "cancelled" }
      end
      proxy.define_singleton_method(method) { |*args| handler.call(*args) }
      Collavre::CliProxy::Client.stub(:new, proxy) do
        request_login_session(operation)
      end
      assert_response(operation == :status ? :success : :conflict)
      state = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal true, state["resumed"]
      assert_equal true, state["authorized"]
      operation == :create ? assert_nil(state["session_id"]) : assert_equal("authorized-session", state["session_id"])
    end
  end

  test "session identifiers from another card or a superseded attempt are rejected before proxy access" do
    set_data("session_id" => "new-session", "session_user_id" => @requester.id)
    get inline_agent_login_session_path(comment_id: @reply.id, session_id: "old-session"), as: :json
    assert_response :conflict
    assert_equal "session_superseded", response.parsed_body.dig("error", "code")
  end

  test "resume requires server authorization and enqueues the original request only once" do
    assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), params: { authorized: true }, as: :json
    end
    assert_response :conflict
    set_data("authorized" => true, "session_user_id" => @requester.id)
    assert_enqueued_jobs 1, only: Collavre::InlineAgentReplayJob do
      2.times { post inline_agent_login_resume_path(comment_id: @reply.id), as: :json; assert_response :success }
    end
    assert @task.reload.trigger_event_payload.dig("engine_login", "resumed")
  end

  test "resume rebuilds edited content and mentions before scheduling" do
    set_data("authorized" => true, "session_user_id" => @requester.id)
    payload = @task.reload.trigger_event_payload.merge(
      "comment" => { "id" => @original.id, "content" => "Removed secret", "quoted_comment_id" => 999 },
      "chat" => { "content" => "Removed secret", "mentioned_user" => { "id" => @owner.id } }
    )
    @task.update!(trigger_event_payload: payload)
    @original.update!(content: "@#{@agent.name}: Updated request")
    expected = payload.except("engine_login").merge(
      "comment" => @original.dispatch_payload[:comment].deep_stringify_keys,
      "chat" => Collavre::SystemEvents::ContextBuilder.reanchor_chat(@original.content)
    )
    assert_enqueued_with(job: Collavre::InlineAgentReplayJob, args: [ @reply.id, @requester.id, @task.id ]) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
    assert_equal [ expected.merge("inline_login_task_id" => @task.id) ], execute_replay_payloads
    assert_not_includes expected.to_json, "Removed secret"
    assert_equal @agent.id, expected.dig("chat", "mentioned_user", "id")
    assert_not expected["comment"].key?("quoted_comment_id")
  end

  test "removing a mention cannot bypass the current topic assignment on replay" do
    set_data("authorized" => true, "session_user_id" => @requester.id)
    @task.update!(trigger_event_payload: @task.trigger_event_payload.merge(
      "chat" => Collavre::SystemEvents::ContextBuilder.reanchor_chat("@#{@agent.name}: Old request")
    ))
    @original.topic.update!(primary_agent_id: users(:ai_bot).id)
    @original.update!(content: "Updated request without mention")
    assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :conflict
    assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
  end

  [ { private: true }, { action: '{"tool":"test"}' },
    { action: '{"tool":"test"}', action_executed_at: Time.current } ].each_with_index do |attributes, index|
    test "source changed to a non-dispatchable comment blocks its author from replay #{index}" do
      set_data("authorized" => true, "session_user_id" => @requester.id)
      login = Collavre::CliProxy::InlineLogin.new(@reply, @requester)
      assert login.accessible?
      @original.update!(attributes)
      assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
        error = assert_raises(Collavre::CliProxy::Client::Error) { login.resume! }
        assert_equal "cannot_retry", error.code
        post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      end
      assert_response :not_found
      assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
    end
  end

  test "partial and cancelled turns cannot be automatically replayed" do
    set_data("authorized" => true, "session_user_id" => @requester.id, "retryable" => false)
    get inline_agent_login_path(comment_id: @reply.id)
    assert_select "[data-agent-connection-resume-url-value]", count: 0
    assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
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
      assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
        post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      end
    end
    assert_response :conflict
    assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
    fake.verify
  end

  [ :immediate, :delayed ].each do |timing|
    [ :false, :nil, :unsuccessful ].each do |failure|
      test "#{timing} enqueue returning #{failure} rolls back the replay claim and allows another attempt" do
        set_data("authorized" => true, "session_user_id" => @requester.id)
        result = case failure
        when :false then false
        when :nil then nil
        else Collavre::InlineAgentReplayJob.new
        end
        scheduler = Object.new
        scheduler.define_singleton_method(:schedule) { |*| [ { timing: timing, delay: 30 } ] }
        failed_enqueue = ->(*_args) { result }

        Collavre::Orchestration::Scheduler.stub(:new, scheduler) do
          # Exercise both perform_later entry points without bypassing the scheduler.
          if timing == :delayed
            configured_job = Collavre::InlineAgentReplayJob.set(wait: 30)
            Collavre::InlineAgentReplayJob.stub(:set, configured_job) do
              configured_job.stub(:perform_later, failed_enqueue) do
                post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
              end
            end
          else
            Collavre::InlineAgentReplayJob.stub(:perform_later, failed_enqueue) do
              post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
            end
          end
          assert_response :conflict
          assert_equal "cannot_retry", response.parsed_body.dig("error", "code")
          assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
          assert @task.trigger_event_payload.dig("engine_login", "authorized")

          assert_enqueued_jobs 1, only: Collavre::InlineAgentReplayJob do
            2.times do
              post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
              assert_response :success
            end
          end
          assert @task.reload.trigger_event_payload.dig("engine_login", "resumed")
        end
      end
    end
  end

  [ :callback, :external_claim ].each do |completion|
    test "#{completion} checks trigger loop completion when login cannot replay the partial turn" do
      parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
      @creative.update_columns(parent_id: parent.id)
      @creative.reload.update!(data: { "trigger" => { "loop" => {
        "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
        "trigger_topic_id" => @original.topic_id
      } } })
      set_data("retryable" => false)
      @task.update!(status: :running)
      @reply.update!(content: "Partial response [STATUS: BLOCKED need credentials]")
      clear_enqueued_jobs

      assert_enqueued_with(job: Collavre::TriggerLoopCheckJob, args: [ @task.id ]) do
        if completion == :callback
          @task.done!
        else
          @task.update_columns(status: "done")
          @task.reload.fire_completion_callbacks_after_external_claim
        end
      end
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
        perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
    end

    test "#{completion} leaves the trigger loop running until the authenticated replay completes" do
      parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
      # Avoid dispatching a drop event while preparing the active loop.
      @creative.update_columns(parent_id: parent.id)
      @creative.reload.update!(data: { "trigger" => { "loop" => {
        "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
        "trigger_topic_id" => @original.topic_id
      } } })
      @task.update!(status: :running)
      assert_no_enqueued_jobs(only: Collavre::TriggerLoopCheckJob) do
        if completion == :callback
          @task.done!
        else
          @task.update_columns(status: "done")
          @task.reload.fire_completion_callbacks_after_external_claim
        end
      end
      assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")

      set_data("authorized" => true, "session_user_id" => @requester.id)
      clear_enqueued_jobs
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      assert_response :success
      payload = nil
      Collavre::AiAgentJob.stub(:perform_now, ->(_agent, _event, context, _identity) { payload = context }) do
        perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
      end
      assert_not payload.key?("engine_login")
      replay = Collavre::Task.create!(name: "Authenticated replay", agent: @agent, creative: @creative,
        topic_id: @original.topic_id, status: :running, trigger_event_name: "comment_created", trigger_event_payload: payload)
      @creative.comments.create!(user: @agent, topic_id: @original.topic_id, task: replay,
        content: "Done [STATUS: DONE]", skip_dispatch: true)
      assert_enqueued_with(job: Collavre::TriggerLoopCheckJob, args: [ replay.id ]) { replay.done! }
      perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
      assert_equal "pending_verification", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
    end
  end

  test "removed agent access prevents replay even after login succeeds" do
    set_data("authorized" => true, "session_user_id" => @requester.id)
    Collavre::CreativeShare.where(creative: @creative, user: @agent).destroy_all
    Collavre::CreativeSharesCache.where(creative: @creative, user: @agent).delete_all
    assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :conflict
    assert_not @task.reload.trigger_event_payload.dig("engine_login", "resumed")
  end

  test "deleted or moved source messages cannot be replayed" do
    @original.update!(topic_id: @creative.topics.create!(name: "Moved", user: @requester).id)
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :success
    assert_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
    post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    assert_response :not_found
    @original.destroy!
    post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    assert_response :not_found
  end

  [ :private, :deleted, :approval, :moved, :agent_access, :gateway, :authorization, :session_owner, :cancelled, :partial, :unclaimed ].each do |change|
    test "delayed replay rejects #{change} changes before execution" do
      queue_delayed_replay
      case change
      when :private then @original.update!(private: true)
      when :deleted then @original.destroy!
      when :approval then @original.update!(action: '{"tool":"test"}')
      when :moved then @original.update!(topic_id: @creative.topics.create!(name: "Moved later", user: @requester).id)
      when :agent_access
        Collavre::CreativeShare.where(creative: @creative, user: @agent).destroy_all
        Collavre::CreativeSharesCache.where(creative: @creative, user: @agent).delete_all
      when :gateway then @gateway.update!(active: false)
      when :authorization then set_data("authorized" => false)
      when :session_owner then set_data("session_user_id" => @owner.id)
      when :cancelled then @task.update!(status: :cancelled)
      when :partial then set_data("retryable" => false)
      when :unclaimed then set_data("resumed" => false)
      end
      assert_no_difference "Collavre::Task.count" do
        assert_empty execute_replay_payloads
      end
      login_data = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal false, login_data["resumed"]
      unless change == :unclaimed
        assert_equal false, login_data["retryable"]
        assert_equal true, login_data["replay_abandoned"]
      end
    end
  end

  test "abandoned replay releases loop completion and refreshes the card only once" do
    parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
    @creative.update_columns(parent_id: parent.id)
    @creative.reload.update!(data: { "trigger" => { "loop" => {
      "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
      "trigger_topic_id" => @original.topic_id, "stuck_conditions" => [ "Login required" ]
    } } })
    queue_delayed_replay
    @gateway.update!(active: false)
    clear_enqueued_jobs

    2.times do |attempt|
      expected = attempt.zero? ? 1 : 0
      assert_enqueued_jobs expected, only: Collavre::TriggerLoopCheckJob do
        assert_enqueued_jobs expected, only: Turbo::Streams::ActionBroadcastJob do
          assert_no_difference "Collavre::Task.count" do
            Collavre::InlineAgentReplayJob.perform_now(@reply.id, @requester.id)
          end
        end
      end
    end
    Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
      perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
    end
    assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
  end

  test "abandoned replay shows a truthful card after authorization is restored" do
    queue_delayed_replay
    set_data("authorized" => false)
    assert_empty execute_replay_payloads
    set_data("authorized" => true)

    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :success
    assert_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
    assert_not_includes response.body, I18n.t("collavre.inline_agent_login.resumed")
    assert_select "[data-agent-connection-resume-url-value]", count: 0
    assert_no_enqueued_jobs(only: Collavre::InlineAgentReplayJob) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :conflict
    assert_equal "cannot_retry", response.parsed_body.dig("error", "code")
  end

  test "abandoning a reply made private does not broadcast it to the creative" do
    queue_delayed_replay
    @reply.update!(private: true)
    set_data("authorized" => false)
    assert_no_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob) do
      assert_empty execute_replay_payloads
    end
    assert_equal false, @task.reload.trigger_event_payload.dig("engine_login", "resumed")
    assert_equal false, @task.trigger_event_payload.dig("engine_login", "retryable")
  end

  test "delayed replay rebuilds edited source text before the agent executes" do
    queue_delayed_replay
    @original.update!(content: "@#{@agent.name}: Current request")
    payloads = execute_replay_payloads
    assert_equal 1, payloads.size
    payload = payloads.first
    assert_equal @original.content, payload.dig("comment", "content")
    assert_equal @original.content, payload.dig("chat", "content")
    assert_equal @agent.id, payload.dig("chat", "mentioned_user", "id")
    assert_not_includes payload.to_json, "Hello"
    assert_equal @requester.id, payload["workspace_user_id"]
  end

  test "delayed replay cannot use a removed mention to bypass topic assignment" do
    @original.update!(content: "@#{@agent.name}: Hello")
    @original.topic.update!(primary_agent_id: users(:ai_bot).id)
    queue_delayed_replay
    @original.update!(content: "No mention anymore")
    assert_no_difference "Collavre::Task.count" do
      assert_empty execute_replay_payloads
    end
  end

  [ :deleted, :private, :approval, :moved, :agent_access, :edited, :card, :task, :detached_card, :assignment, :co_moved ].each do |change|
    test "dispatch admission revalidates #{change} after replay payload preparation" do
      queue_delayed_replay
      dispatch = Collavre::AiAgentJob.method(:perform_now)
      mutate_then_dispatch = lambda do |*args|
        case change
        when :assignment then @original.topic.update!(primary_agent_id: users(:ai_bot).id)
        when :co_moved
          destination = @creative.topics.create!(name: "Co-moved at dispatch", user: @requester)
          [ @original, @reply ].each { |comment| comment.update!(topic: destination) }
        when :deleted then @original.destroy!
        when :private then @original.update!(private: true)
        when :approval then @original.update!(action: '{"tool":"test"}')
        when :moved then @original.update!(topic_id: @creative.topics.create!(name: "Moved at dispatch", user: @requester).id)
        when :agent_access
          Collavre::CreativeShare.where(creative: @creative, user: @agent).destroy_all
          Collavre::CreativeSharesCache.where(creative: @creative, user: @agent).delete_all
        when :edited then @original.update!(content: "Current dispatch text")
        when :card then @reply.destroy!
        when :task then @task.destroy!
        when :detached_card then @reply.update!(task: nil)
        end
        dispatch.call(*args)
      end
      Collavre::AiAgentJob.stub(:perform_now, mutate_then_dispatch) do
        if change == :edited
          payloads = execute_replay_payloads
          assert_equal [ "Current dispatch text" ], payloads.map { |payload| payload.dig("comment", "content") }
          assert_equal "Current dispatch text", payloads.first.dig("chat", "content")
        else
          assert_difference "Collavre::Task.count", change == :task ? -1 : 0 do
            assert_empty execute_replay_payloads
          end
          assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "replay_abandoned") unless change == :task
        end
      end
    end
  end

  test "dispatch admission ignores cached source text from earlier validation" do
    queue_delayed_replay
    dispatch = Collavre::AiAgentJob.method(:perform_now)
    Collavre::Comment.cache do
      Collavre::AiAgentJob.stub(:perform_now, lambda { |*args|
        connection = Collavre::Comment.connection
        table = connection.quote_table_name(Collavre::Comment.table_name)
        # Bypass AR cache invalidation to model an edit on another connection.
        sql = "UPDATE #{table} SET content = 'Uncached current request' WHERE id = #{@original.id}"
        raw = connection.raw_connection
        raw.respond_to?(:exec) ? raw.exec(sql) : raw.execute(sql)
        dispatch.call(*args)
      }) do
        payloads = execute_replay_payloads
        assert_equal [ "Uncached current request" ], payloads.map { |payload| payload.dig("comment", "content") }
      end
    end
  end

  test "replay admission rolls back its task and source changes together on failure" do
    queue_delayed_replay
    identity = [ @reply.id, @requester.id, @task.id ]
    assert_no_difference "Collavre::Task.count" do
      assert_raises(RuntimeError) do
        Collavre::CliProxy::InlineReplayAdmission.call({}, identity) do |payload|
          @original.update!(content: "Uncommitted edit")
          Collavre::Task.create!(name: "Uncommitted replay", agent: @agent, status: :running,
            creative: @creative, topic_id: @original.topic_id, trigger_event_payload: payload)
          raise "Admission failed"
        end
      end
    end
    assert_equal "Hello", @original.reload.content
  end

  test "replay queue contains only ids and keeps the scheduler delay" do
    queue_delayed_replay
    job = enqueued_jobs.find { |entry| entry[:job] == Collavre::InlineAgentReplayJob }
    assert_equal [ @reply.id, @requester.id, @task.id ], job[:args]
    assert_in_delta 30.seconds.from_now.to_f, job[:at], 2
    assert_equal false, Collavre::InlineAgentReplayJob.enqueue_after_transaction_commit
  end

  test "legacy queue entries without task ids still replay after validation" do
    queue_delayed_replay
    clear_enqueued_jobs
    payloads = []
    Collavre::AiAgentJob.stub(:perform_now, ->(_agent, _event, payload, _identity) { payloads << payload }) do
      Collavre::InlineAgentReplayJob.perform_now(@reply.id, @requester.id)
    end
    assert_equal [ @original.id ], payloads.map { |payload| payload.dig("comment", "id") }
  end

  test "replay ignores a deleted card or user without invoking the agent" do
    Collavre::AiAgentJob.stub(:perform_now, ->(*) { flunk "must not start an agent" }) do
      Collavre::InlineAgentReplayJob.perform_now(-1, @requester.id)
      Collavre::InlineAgentReplayJob.perform_now(@reply.id, -1)
    end
  end

  [ :card, :user ].each do |missing|
    test "missing #{missing} abandons the queued replay and releases loop completion once" do
      parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
      @creative.update_columns(parent_id: parent.id)
      @creative.reload.update!(data: { "trigger" => { "loop" => {
        "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
        "trigger_topic_id" => @original.topic_id
      } } })
      # A separate shared manager can be deleted without deleting the creative,
      # source comment, agent or workspace owned by other users.
      if missing == :user
        @gateway.update!(workspace_mode: :shared)
        @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
        set_data("workspace_id" => @workspace.id)
        @requester = Collavre::User.create!(name: "Deleted manager", email: "deleted-manager@example.com",
          password: "password123", system_admin: true)
        Collavre::CreativeShare.create!(creative: @creative, user: @requester, permission: :feedback)
        Collavre::CreativeSharesCache.find_or_create_by!(creative: @creative, user: @requester, permission: :feedback)
        sign_in_as(@requester, password: "password123")
      end
      queue_delayed_replay
      args = enqueued_jobs.find { |entry| entry[:job] == Collavre::InlineAgentReplayJob }[:args]
      clear_enqueued_jobs
      assert_enqueued_jobs(missing == :card ? 1 : 0, only: Collavre::TriggerLoopCheckJob) do
        missing == :user ? @requester.destroy! : @reply.destroy!
      end
      2.times do |attempt|
        expected = missing == :user && attempt.zero? ? 1 : 0
        assert_enqueued_jobs expected, only: Collavre::TriggerLoopCheckJob do
          assert_enqueued_jobs(missing == :card ? 0 : expected, only: Turbo::Streams::ActionBroadcastJob) do
            Collavre::AiAgentJob.stub(:perform_now, ->(*) { flunk "missing identity cannot run" }) do
              Collavre::InlineAgentReplayJob.perform_now(*args)
            end
          end
        end
      end
      state = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal false, state["resumed"]
      assert_equal false, state["retryable"]
      assert_equal true, state["replay_abandoned"]
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
        perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
      assert_equal 1, @creative.comments.where(user_id: nil, content: I18n.t("collavre.inline_agent_login.replay_abandoned")).count
    end
  end

  test "deleted replay task is a no-op even if the card remains" do
    queue_delayed_replay
    @task.destroy!
    clear_enqueued_jobs
    Collavre::AiAgentJob.stub(:perform_now, ->(*) { flunk "deleted task cannot run" }) do
      assert_no_enqueued_jobs { Collavre::InlineAgentReplayJob.perform_now(@reply.id, @requester.id, @task.id) }
    end
  end

  test "replay fails closed when the source disappears during access checks" do
    queue_delayed_replay
    login = Collavre::CliProxy::InlineLogin.new(@reply.reload, @requester)
    login.stub(:manageable?, -> { @original.destroy!; true }) do
      error = assert_raises(Collavre::CliProxy::Client::Error) { login.replay_payload }
      assert_equal "cannot_retry", error.code
    end
  end

  [ :topic, :creative ].each do |destination|
    test "replay rejects source and card moved together to another #{destination}" do
      queue_delayed_replay
      target = destination == :creative ? Collavre::Creative.create!(user: @requester, description: "Private destination") : @creative
      topic = target.topics.create!(name: "Moved pair", user: @requester)
      [ @original, @reply ].each { |comment| comment.update!(creative: target, topic: topic) }
      assert_no_difference "Collavre::Task.count" do
        assert_empty execute_replay_payloads
      end
      assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "replay_abandoned")
    end
  end

  test "assignment rejection before admission releases the replay claim" do
    queue_delayed_replay
    dispatch = Collavre::AiAgentJob.method(:perform_now)
    Collavre::AiAgentJob.stub(:perform_now, lambda { |*args|
      @original.topic.update!(primary_agent_id: users(:ai_bot).id)
      dispatch.call(*args)
    }) do
      assert_no_difference "Collavre::Task.count" do
        assert_empty execute_replay_payloads
      end
    end
    state = @task.reload.trigger_event_payload.fetch("engine_login")
    assert_equal false, state["resumed"]
    assert_equal false, state["retryable"]
    assert_equal true, state["replay_abandoned"]
  end

  [ :deleted, :private, :moved, :approval, :gateway ].each do |change|
    test "abandoned card renders generic explanation after #{change} without enabling actions" do
      queue_delayed_replay
      case change
      when :deleted then @original.destroy!
      when :private then @original.update!(private: true)
      when :moved then @original.update!(topic: @creative.topics.create!(name: "Moved source", user: @requester))
      when :approval then @original.update!(action: '{"tool":"test"}')
      when :gateway then @gateway.update!(active: false)
      end
      assert_empty execute_replay_payloads
      Collavre::CliProxy::Client.stub(:new, ->(*) { flunk "Generic card must not contact the proxy" }) do
        get inline_agent_login_path(comment_id: @reply.id)
        assert_response :success
        assert_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
        assert_select "[data-controller=agent-connection]", count: 0
        post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
        assert_response :not_found
      end
      sign_in_as(@owner, password: "password")
      get inline_agent_login_path(comment_id: @reply.id)
      assert_response :not_found
    end
  end

  [ false, true ].each do |claimed|
    test "moving a topic abandons its #{claimed ? 'claimed' : 'pending'} login and completes the original loop" do
      queue_delayed_replay if claimed
      parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
      @creative.update_columns(parent_id: parent.id)
      @creative.reload.update!(data: { "trigger" => { "loop" => {
        "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
        "trigger_topic_id" => nil
      } } })
      destination = Collavre::Creative.create!(user: @requester, description: "Moved login")
      topic = @original.topic
      topic.update!(name: "Moving login")
      clear_enqueued_jobs

      assert_enqueued_jobs 1, only: Collavre::TriggerLoopCheckJob do
        Collavre::Topics::TopicMove.new(topic: topic, target_creative: destination).call
      end

      assert_equal destination.id, @original.reload.creative_id
      assert_equal destination.id, @reply.reload.creative_id
      assert_equal @creative.id, @task.reload.creative_id
      data = @task.trigger_event_payload.fetch("engine_login")
      assert_equal false, data["retryable"]
      assert_equal false, data["resumed"]
      assert_equal true, data["replay_abandoned"]
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
        perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
      notice = @creative.comments.where(user_id: nil).last
      assert_equal I18n.t("collavre.inline_agent_login.replay_abandoned"), notice.content
      assert_equal @creative.main_topic.id, notice.topic_id
      get inline_agent_login_path(comment_id: @reply.id)
      assert_response :success
      assert_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      assert_response :not_found
    end
  end

  [ :source, :card ].each do |deleted|
    test "deleting #{deleted} before resume abandons the login and completes the loop once" do
      parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
      @creative.update_columns(parent_id: parent.id)
      @creative.reload.update!(data: { "trigger" => { "loop" => {
        "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
        "trigger_topic_id" => @original.topic_id
      } } })
      clear_enqueued_jobs
      target = deleted == :source ? @original : @reply
      assert_enqueued_jobs 1, only: Collavre::TriggerLoopCheckJob do
        target.destroy!
      end
      data = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal false, data["retryable"]
      assert_equal false, data["resumed"]
      assert_equal true, data["replay_abandoned"]
      assert_no_enqueued_jobs only: Collavre::TriggerLoopCheckJob do
        target.send(:abandon_pending_logins)
      end
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
        perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
      if deleted == :source
        get inline_agent_login_path(comment_id: @reply.id)
        assert_response :success
        assert_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
      end
    end
  end

  [ :private, :topic, :creative ].each do |change|
    test "#{change} source revocation after replay admission cancels dispatch and settles the original login" do
      queue_delayed_replay
      client = Object.new
      client.define_singleton_method(:chat) { |*| raise "withdrawn source reached the provider" }
      client.define_singleton_method(:handed_off?) { false }
      Collavre::AiClient.stub(:new, ->(*) { revoke_replay_source(change); client }) do
        perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
      end
      replay = Collavre::Task.where(agent: @agent).where.not(id: @task.id).order(:id).last
      assert replay.cancelled?
      data = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal false, data["resumed"]
      assert_equal false, data["retryable"]
      assert_equal true, data["replay_abandoned"]
    end
  end

  [ :private, :action, :destroy, :topic, :creative ].each do |withdrawal|
    test "#{withdrawal} source withdrawal cancels an approval paused replay and settles its login" do
      queue_delayed_replay
      replay = nil
      service = Object.new
      service.define_singleton_method(:call) { raise Collavre::ApprovalPendingError }
      Collavre::AiAgentService.stub(:new, ->(task) { replay = task; task.update!(status: :pending_approval); service }) do
        perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
      end
      assert replay.reload.pending_approval?
      tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
      assert_equal 1, tracker.active_jobs

      revoke_replay_source(withdrawal)

      assert replay.reload.cancelled?
      assert_equal 0, tracker.active_jobs
      data = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal false, data["resumed"]
      assert_equal false, data["retryable"]
      assert_equal true, data["replay_abandoned"]
    end
  end

  test "stopping a deferred replay settles its original claim even with both comments intact" do
    queue_delayed_replay
    Collavre::Orchestration::TopicSlot.stub(:available_for?, false) do
      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, nil) do
        assert_empty execute_replay_payloads
      end
    end
    replay = Collavre::Task.where(agent: @agent, status: "queued").sole
    assert_equal @task.id, replay.trigger_event_payload["inline_login_task_id"]
    assert_equal "queued", replay.cancel_if_active!
    assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "replay_abandoned")
    assert Collavre::Comment.exists?(@original.id)
    assert Collavre::Comment.exists?(@reply.id)
  end

  test "coalescing an admitted replay keeps its card resumed until the survivor is stopped" do
    queue_delayed_replay
    Collavre::Orchestration::TopicSlot.stub(:available_for?, false) do
      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, nil) do
        assert_empty execute_replay_payloads
      end
    end
    replay = Collavre::Task.where(agent: @agent, status: "queued").sole
    source = @creative.comments.create!(user: @requester, content: "Follow up", topic_id: @original.topic_id, skip_dispatch: true)
    survivor = replay.dup
    survivor.trigger_event_payload = Collavre::Orchestration::TaskCoalescer.reanchor_payload(
      replay.trigger_event_payload.except("inline_login_task_id"), source)
    survivor.save!
    clear_enqueued_jobs
    assert_no_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob) do
      assert_equal [ replay.id ], Collavre::Orchestration::TaskCoalescer.coalesce!(survivor)
    end
    assert_equal [ @task.id ], survivor.reload.trigger_event_payload["inline_login_task_ids"]
    assert_includes survivor.trigger_event_payload["merged_comment_ids"], @original.id
    assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "resumed")
    get inline_agent_login_path(comment_id: @reply.id)
    assert_response :success
    assert_not_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
    assert_enqueued_jobs 1, only: Turbo::Streams::ActionBroadcastJob do
      survivor.cancel_if_active!
    end
    assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "replay_abandoned")
  end

  [ :private, :action, :destroy, :topic, :creative ].each do |withdrawal|
    test "#{withdrawal} after a successful replay preserves its completed login card" do
      queue_delayed_replay
      assert_equal 1, execute_replay_payloads.size
      before = @task.reload.trigger_event_payload.fetch("engine_login").deep_dup
      assert_equal true, before["replay_completed"]
      assert_equal false, before["retryable"]

      revoke_replay_source(withdrawal)

      assert_equal before, @task.reload.trigger_event_payload.fetch("engine_login")
      Collavre::CliProxy::Client.stub(:new, ->(*) { flunk "Completed cards must not contact the proxy" }) do
        get inline_agent_login_path(comment_id: @reply.id)
      end
      assert_response :success
      assert_includes response.body, I18n.t("collavre.inline_agent_login.resumed")
      assert_not_includes response.body, I18n.t("collavre.inline_agent_login.replay_abandoned")
      assert_select "[data-controller=agent-connection]", count: 0
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
      assert_response :not_found
      sign_in_as(@owner, password: "password")
      get inline_agent_login_path(comment_id: @reply.id)
      assert_response :not_found
    end
  end

  test "deleting a completed login card preserves the successful claim" do
    queue_delayed_replay
    execute_replay_payloads
    before = @task.reload.trigger_event_payload.deep_dup
    @reply.destroy!
    assert_equal before, @task.reload.trigger_event_payload
    assert_equal true, @task.trigger_event_payload.dig("engine_login", "replay_completed")
  end

  [ :done, :cancelled, :failed ].each do |ending|
    test "repeated authentication settles every ancestor claim when the final replay is #{ending}" do
      logins = [ @task ]
      2.times do
        advance_reauthentication
        logins << @task
      end
      logins.each do |login|
        assert_equal true, login.reload.trigger_event_payload.dig("engine_login", "retryable")
        assert_not login.trigger_event_payload.dig("engine_login", "replay_completed")
      end

      queue_delayed_replay
      if ending == :done
        client = Object.new
        client.define_singleton_method(:chat) { |*, **, &block| block.call("Authenticated response") }
        client.define_singleton_method(:last_handoff_failed?) { false }
        client.define_singleton_method(:handed_off?) { true }
        Collavre::AiClient.stub(:new, client) { perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob) }
        result = @creative.comments.find_by!(content: "Authenticated response")
        assert result.task.done?
        payload = result.task.trigger_event_payload
      else
        Collavre::Orchestration::TopicSlot.stub(:available_for?, false) do
          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, nil) { assert_empty execute_replay_payloads }
        end
        replay = Collavre::Task.where(agent: @agent, status: "queued").sole
        payload = replay.trigger_event_payload
        replay.update!(status: ending)
      end
      assert_equal logins.map(&:id).sort, Collavre::CliProxy::ReplayClaims.ids(payload).sort
      assert_equal @task.id, payload["inline_login_task_id"]
      snapshots = logins.map do |login|
        data = login.reload.trigger_event_payload.fetch("engine_login")
        assert_equal false, data["retryable"]
        assert_equal ending == :done, data["resumed"]
        assert_equal true, data[ending == :done ? "replay_completed" : "replay_abandoned"]
        data.deep_dup
      end
      @original.destroy!
      assert_equal snapshots, logins.map { |login| login.reload.trigger_event_payload.fetch("engine_login") }
    end
  end

  test "successful replay does not abandon its original login" do
    queue_delayed_replay
    assert_equal 1, execute_replay_payloads.size
    assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "resumed")
    assert_not @task.trigger_event_payload.dig("engine_login", "replay_abandoned")
  end

  %w[running queued pending pending_approval].product(%w[cancelled failed escalated]).each do |initial, ending|
    test "#{initial} replay ending #{ending} settles its login claim and loop once" do
      parent = Collavre::Creative.create!(user: @requester, description: "Trigger parent", data: { "trigger" => { "on_child_enter" => true } })
      @creative.update_columns(parent_id: parent.id)
      @creative.reload.update!(data: { "trigger" => { "loop" => {
        "state" => "running", "current_iteration" => 1, "cooldown_seconds" => 0,
        "trigger_topic_id" => @original.topic_id
      } } })
      queue_delayed_replay
      replay = nil
      service = Object.new
      service.define_singleton_method(:call) { raise Collavre::ApprovalPendingError }
      Collavre::AiAgentService.stub(:new, ->(task) { replay = task; service }) do
        perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
      end
      assert_equal @task.id, replay.reload.trigger_event_payload["inline_login_task_id"]
      replay.update_columns(status: initial)
      clear_enqueued_jobs
      assert_enqueued_with(job: Collavre::TriggerLoopCheckJob, args: [ @task.id ]) do
        replay.update!(status: ending)
      end
      assert_equal 1, enqueued_jobs.count { |job| job[:job] == Collavre::TriggerLoopCheckJob }
      data = @task.reload.trigger_event_payload.fetch("engine_login")
      assert_equal false, data["resumed"]
      assert_equal false, data["retryable"]
      assert_equal true, data["replay_abandoned"]
      assert_no_enqueued_jobs(only: Collavre::TriggerLoopCheckJob) do
        replay.fire_completion_callbacks_after_external_claim
      end
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
        perform_enqueued_jobs(only: Collavre::TriggerLoopCheckJob)
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @creative.data.dig("trigger", "loop", "current_iteration")
    end
  end

  test "status preserves an explicitly empty list after filtering every custom flow" do
    proxy = Object.new
    proxy.define_singleton_method(:engines) do
      { "data" => [ { "engine" => "codex", "flow" => "custom", "flows" => [ "custom" ], "base_url_flows" => [ "custom" ] } ] }
    end
    Collavre::CliProxy::Client.stub(:new, proxy) { get inline_agent_login_status_path(comment_id: @reply.id), as: :json }
    assert_response :success
    assert_empty response.parsed_body["engines"].first["flows"]
  end

  private

  def advance_reauthentication
    queue_delayed_replay
    error = Collavre::CliProxy::EngineUnauthenticatedError.new(engine: "codex", workspace: @workspace)
    client = Object.new
    client.define_singleton_method(:chat) { |*, **| raise error }
    client.define_singleton_method(:last_handoff_failed?) { true }
    client.define_singleton_method(:handed_off?) { false }
    Collavre::AiClient.stub(:new, client) do
      perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
    end
    @task = Collavre::Task.where(agent: @agent).order(:id).last
    @reply = @task.reply_comment
    assert @task.done?
    assert @reply
    assert_equal true, @task.trigger_event_payload.dig("engine_login", "retryable")
  end

  def revoke_replay_source(change)
    case change
    when :destroy then @original.destroy!
    when :private then @original.update!(private: true)
    when :action then @original.update!(action: '{"tool":"approval"}')
    when :topic, :creative
      destination = change == :creative ? Collavre::Creative.create!(user: @requester, description: "Private destination") : @creative
      topic = destination.topics.create!(name: "Destination", user: @requester)
      options = change == :creative ? { target_creative_id: destination.id } : { target_topic_id: topic.id }
      Collavre::CommentMoveService.new(creative: @creative, user: @requester).call(comment_ids: [ @original.id ], **options)
    end
  end

  def request_login_session(operation)
    path = inline_agent_login_session_path(comment_id: @reply.id, session_id: "authorized-session")
    case operation
    when :create then post inline_agent_login_sessions_path(comment_id: @reply.id), params: { flow: "api-key" }, as: :json
    when :poll then get path, as: :json
    when :submit then post path, params: { auth_secret: "secret" }, as: :json
    when :cancel then delete path, as: :json
    when :status then get inline_agent_login_status_path(comment_id: @reply.id), as: :json
    end
  end

  def queue_delayed_replay
    set_data("authorized" => true, "session_user_id" => @requester.id)
    clear_enqueued_jobs
    scheduler = Object.new
    scheduler.define_singleton_method(:schedule) { |*| [ { timing: :delayed, delay: 30 } ] }
    Collavre::Orchestration::Scheduler.stub(:new, scheduler) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
  end

  def execute_replay_payloads
    payloads = []
    service = Object.new
    service.define_singleton_method(:call) { nil }
    Collavre::AiAgentService.stub(:new, ->(task) { payloads << task.trigger_event_payload; service }) do
      perform_enqueued_jobs(only: Collavre::InlineAgentReplayJob)
    end
    payloads
  end

  def set_data(values)
    payload = @task.reload.trigger_event_payload
    @task.update!(trigger_event_payload: payload.merge("engine_login" => payload.fetch("engine_login").merge(values)))
  end
end
