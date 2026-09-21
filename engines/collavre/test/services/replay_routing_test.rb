# frozen_string_literal: true

require "test_helper"

class ReplayRoutingTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    gateway = Collavre::AgentGateway.create!(owner: @user, name: "Routing gateway",
      base_url: "https://proxy.example.com", admin_key: "admin", completion_key: "completion", workspace_mode: :shared)
    @agent = Collavre::User.create!(name: "Routing agent", email: "routing@ai.local", password: SecureRandom.hex(24),
      system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @user.id, agent_gateway: gateway)
    @creative = Collavre::Creative.create!(user: @user, description: "Replay routing")
    Collavre::CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback)
    Collavre::CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
    @source = @creative.comments.create!(user: @user, content: "@#{@agent.name}: Original", skip_dispatch: true)
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
    @claim = Collavre::Task.create!(name: "Login", agent: @agent, status: :done, creative: @creative,
      topic_id: @source.topic_id, trigger_event_payload: { "engine_login" => { "workspace_id" => workspace.id } })
    @payload = @source.dispatch_payload.deep_stringify_keys.merge("inline_login_task_ids" => [ @claim.id ], "workspace_user_id" => nil)
  end

  %i[missing private approval topic creative].each do |change|
    test "a #{change} anchor cannot be authorized by its cached mention or a merged mention" do
      merged = @creative.comments.create!(user: @user, content: "@#{@agent.name}: Extra", skip_dispatch: true)
      @payload["merged_comment_ids"] = [ merged.id ]
      assert Collavre::CliProxy::ReplayRouting.permitted?(@payload, @agent), "The unchanged anchor must authorize this replay"
      # Model a reader before the source's after_commit revocation scan runs.
      case change
      when :missing then @source.delete
      when :private then @source.update_columns(private: true)
      when :approval then @source.update_columns(action: '{"tool":"approval"}')
      when :topic
        topic = @creative.topics.create!(user: @user, name: "Elsewhere")
        @source.update_columns(topic_id: topic.id)
      when :creative
        other = Collavre::Creative.create!(user: @user, description: "Elsewhere")
        @source.update_columns(creative_id: other.id)
      end

      assert_nil Collavre::CliProxy::ReplayRouting.prepare(@payload, @agent)
      assert_not Collavre::CliProxy::ReplayRouting.permitted?(@payload, @agent)
    end
  end

  test "refresh replaces cached mentions without changing the caller payload or turn ownership" do
    cached = @payload.deep_dup
    @source.update!(content: "@#{@agent.name}: Edited")

    current = Collavre::CliProxy::ReplayRouting.prepare(@payload, @agent)

    assert_equal cached, @payload
    assert_equal @source.content, current.dig("chat", "content")
    assert_equal [ @agent.id ], Collavre::SystemEvents::ContextBuilder.mentioned_ids_in(current)
    assert_equal [ @claim.id ], current["inline_login_task_ids"]
    assert current.key?("workspace_user_id")
    assert_nil current["workspace_user_id"]
    assert_nil current[Collavre::Orchestration::TaskCoalescer::ACQUIRED_ANCHOR_KEY]
  end
end
