require "test_helper"

class ReplayWorkspaceTest < ActiveSupport::TestCase
  setup do
    @owner = users(:two)
    @requester = users(:three)
    @gateway = Collavre::AgentGateway.create!(owner: @owner, name: "Replay binding",
      base_url: "https://proxy.example.com", admin_key: "admin", completion_key: "completion",
      identity_secret: "c" * 32, workspace_mode: :per_user)
    @agent = Collavre::User.create!(name: "Binding agent", email: "binding@ai.local", password: SecureRandom.hex(24),
      system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @owner.id, agent_gateway: @gateway)
    @creative = Collavre::Creative.create!(user: @requester, description: "Replay binding")
    @source = @creative.comments.create!(user: @requester, content: "Request", skip_dispatch: true)
    @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @requester)
    @payload = { "creative" => { "id" => @creative.id }, "topic" => { "id" => @source.topic_id },
      "comment" => { "id" => @source.id }, "workspace_user_id" => @requester.id }
    @claim = Collavre::Task.create!(name: "Login", agent: @agent, status: :done, creative: @creative,
      topic_id: @source.topic_id, trigger_event_payload: @payload.merge("engine_login" => { "workspace_id" => @workspace.id }))
    @payload["inline_login_task_id"] = @claim.id
  end

  test "ordinary turns do not query workspace bindings" do
    Collavre::Task.stub(:uncached, ->(*) { flunk "Ordinary turn must not query" }) do
      assert permitted?(@payload.except("inline_login_task_id"))
    end
  end

  test "every query bypasses a warmed worker cache and returns the current binding" do
    Collavre::Task.cache do
      assert permitted?
      queries = []
      callback = ->(*args) { queries << args.last if args.last[:sql].start_with?("SELECT") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { assert permitted? }
      assert queries.any?
      assert queries.none? { |query| query[:cached] }, "Handoff cannot trust an earlier workspace snapshot"
    end
  end

  %i[missing workspace_missing wrong_agent wrong_creative wrong_topic no_metadata other_workspace].each do |change|
    test "rejects #{change} ancestor even when the newest login is valid" do
      ancestor = @claim.dup
      ancestor.save!
      @payload["inline_login_task_ids"] = [ ancestor.id ]
      case change
      when :missing then ancestor.destroy!
      when :workspace_missing then ancestor.update!(trigger_event_payload: { "engine_login" => { "workspace_id" => -1 } })
      when :wrong_agent then ancestor.update!(agent: users(:ai_bot))
      when :wrong_creative then ancestor.update!(creative: Collavre::Creative.create!(user: @requester, description: "Other"))
      when :wrong_topic then ancestor.update!(topic_id: @creative.topics.create!(name: "Another topic", user: @requester).id)
      when :no_metadata then ancestor.update!(trigger_event_payload: {})
      when :other_workspace
        other = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
        ancestor.update!(trigger_event_payload: { "engine_login" => { "workspace_id" => other.id } })
      end
      assert_not permitted?
    end
  end

  %i[proxy_workspace_id proxy_credential_id].each do |attribute|
    test "rejects changed #{attribute} without resolving another workspace" do
      @workspace.update!(attribute => "replacement")
      assert_not permitted?
      assert_equal [ @workspace.id ], Collavre::AgentWorkspace.where(agent: @agent).pluck(:id)
    end
  end

  test "rejects a deleted workspace even if a replacement already exists" do
    @workspace.destroy!
    Collavre::AgentWorkspace.resolve!(agent: @agent, user: @requester)
    assert_not permitted?
  end

  test "rejects an agent no longer using CLI proxy with a stale agent instance" do
    Collavre::User.find(@agent.id).update!(llm_vendor: "openai", agent_gateway: nil)
    assert_not permitted?
  end

  test "per-user binding follows source principal and never an explicit AI or nil principal" do
    assert permitted?(@payload.except("workspace_user_id"))
    [ nil, @agent.id, @owner.id, -1 ].each do |id|
      assert_not permitted?(@payload.merge("workspace_user_id" => id))
    end
    @source.update!(user: @agent)
    assert_not permitted?(@payload.except("workspace_user_id"))
    owner_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    @claim.update!(trigger_event_payload: { "engine_login" => { "workspace_id" => owner_workspace.id } })
    assert permitted?(@payload.except("workspace_user_id")), "AI sources use the normal creator fallback"
  end

  test "shared binding ignores the human principal and permits token rotation" do
    @gateway.update!(workspace_mode: :shared)
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
    @claim.update!(trigger_event_payload: { "engine_login" => { "workspace_id" => workspace.id } })
    workspace.rotate_tokens!
    assert permitted?
    assert permitted?(@payload.merge("workspace_user_id" => nil))
  end

  private

  def permitted?(payload = @payload)
    Collavre::CliProxy::ReplayWorkspace.permitted?(payload, @agent)
  end
end
