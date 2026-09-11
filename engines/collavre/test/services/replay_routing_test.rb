# frozen_string_literal: true

require "test_helper"

class ReplayRoutingTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @agent = users(:ai_bot)
    @creative = Collavre::Creative.create!(user: @user, description: "Replay routing")
    Collavre::CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback)
    Collavre::CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
    @source = @creative.comments.create!(user: @user, content: "@#{@agent.name}: Original", skip_dispatch: true)
    @payload = @source.dispatch_payload.deep_stringify_keys.merge("inline_login_task_ids" => [ 42 ], "workspace_user_id" => nil)
  end

  %i[missing private approval topic creative].each do |change|
    test "a #{change} anchor cannot be authorized by its cached mention or a merged mention" do
      merged = @creative.comments.create!(user: @user, content: "@#{@agent.name}: Extra", skip_dispatch: true)
      @payload["merged_comment_ids"] = [ merged.id ]
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
    assert_equal [ 42 ], current["inline_login_task_ids"]
    assert current.key?("workspace_user_id")
    assert_nil current["workspace_user_id"]
    assert_nil current[Collavre::Orchestration::TaskCoalescer::ACQUIRED_ANCHOR_KEY]
  end
end
