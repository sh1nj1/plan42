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
    assert_enqueued_with(job: Collavre::InlineAgentReplayJob, args: [ @reply.id, @owner.id ]) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
    assert_equal [ expected ], execute_replay_payloads
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
    assert_enqueued_with(job: Collavre::InlineAgentReplayJob, args: [ @reply.id, @requester.id ]) do
      post inline_agent_login_resume_path(comment_id: @reply.id), as: :json
    end
    assert_response :success
    assert_equal [ expected ], execute_replay_payloads
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
      Collavre::AiAgentJob.stub(:perform_now, ->(_agent, _event, context) { payload = context }) do
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
    end
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

  test "replay queue contains only ids and keeps the scheduler delay" do
    queue_delayed_replay
    job = enqueued_jobs.find { |entry| entry[:job] == Collavre::InlineAgentReplayJob }
    assert_equal [ @reply.id, @requester.id ], job[:args]
    assert_in_delta 30.seconds.from_now.to_f, job[:at], 2
    assert_equal false, Collavre::InlineAgentReplayJob.enqueue_after_transaction_commit
  end

  test "replay ignores a deleted card or user without invoking the agent" do
    Collavre::AiAgentJob.stub(:perform_now, ->(*) { flunk "must not start an agent" }) do
      Collavre::InlineAgentReplayJob.perform_now(-1, @requester.id)
      Collavre::InlineAgentReplayJob.perform_now(@reply.id, -1)
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

  private

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
