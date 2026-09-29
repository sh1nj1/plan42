# frozen_string_literal: true

require "test_helper"

class Collavre::KollavyAccessScopeTest < ActiveSupport::TestCase
  setup do
    @alice, @bob = users(:one), users(:two)
    @alice_inbox = Collavre::Creative.inbox_for(@alice)
    @bob_inbox = Collavre::Creative.inbox_for(@bob)
    @agent = Collavre::Kollavy.seed!
    @alice_child = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, description: "shared-word Alice")
    @bob_child = Collavre::Creative.create!(user: @bob, parent: @bob_inbox, description: "shared-word Bob secret")
    @bob_comment = Collavre::Comment.create!(user: @bob, creative: @bob_inbox, content: "private-search secret", skip_dispatch: true)
    @task = Collavre::Task.create!(agent: @agent, creative: @alice_inbox, name: "Alice asks")
    Collavre::Current.user = @agent
    Collavre::Current.agent_turn = { task: @task, user: @alice }
    @retrieval = Collavre::Tools::CreativeRetrievalService.new
  end

  teardown { Collavre::Current.reset }

  test "human approval cannot lend owner grants or escape the Kollavy conversation" do
    outside = Collavre::Creative.create!(user: @alice, description: "Outside unchanged")
    Collavre::CreativeShare.create!(creative: outside, user: @agent, permission: :write)
    allowed = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, description: "Allowed original")
    Collavre::CreativeShare.create!(creative: allowed, user: @agent, permission: :write)
    [ @alice_child, outside, allowed ].each do |target|
      args = { "id" => target.id, "description" => "Approved edit" }
      @task.update!(status: "pending_approval", pending_tool_call: {
        "tool_name" => "creative_update_service", "tool_call_id" => "call-#{target.id}", "arguments" => args
      })
      comment = @alice_inbox.comments.create!(user: @agent, approver: @alice, content: "Approve edit",
        action: { action: "execute_tool", tool_name: "creative_update_service", arguments: args,
          resume: { task_id: @task.id, tool_call_id: "call-#{target.id}" } }.to_json)
      original = target.description
      Collavre::Current.set(user: @alice, agent_turn: nil) do
        Collavre::AiAgentJob.stub(:perform_later, nil) do
          Collavre::Comments::ActionExecutor.new(comment: comment, executor: @alice).call
        end
        assert_equal @alice, Collavre::Current.user
        assert_nil Collavre::Current.agent_turn
      end
      if target == allowed
        assert_includes target.reload.description, "Approved edit"
      else
        assert_equal original, target.reload.description
      end
    end
  end

  test "review batches capture scoped create update and delete without applying them" do
    Collavre::CreativeShare.find_by!(creative: @alice_inbox, user: @agent).update!(permission: :admin)
    @alice_inbox.update!(data: @alice_inbox.data.merge("ai_write_policy" => "review"))
    deleted = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, description: "Keep until approved")
    original_turn = Collavre::Current.agent_turn
    result = Collavre::Tools::CreativeBatchService.new.call(operations: [
      { "action" => "create", "parent_id" => @alice_inbox.id, "description" => "Draft child" },
      { "action" => "update", "id" => @alice_child.id, "description" => "Draft edit" },
      { "action" => "delete", "id" => deleted.id }
    ])

    assert result[:success], result.inspect
    assert result[:pending_review], result.inspect
    draft = Collavre::CreativeChangeSet.find(result[:change_set_id])
    assert_equal @task.id, draft.task_id
    assert_equal @agent.id, draft.user_id
    assert_equal "draft", draft.status
    assert_operator draft.creative_changes.count, :>=, 3
    assert_equal "shared-word Alice", @alice_child.reload.description
    assert Collavre::Creative.exists?(deleted.id)
    refute Collavre::Creative.exists?(description: "Draft child")
    assert_same original_turn, Collavre::Current.agent_turn
    assert_nil Collavre::Current.draft_capture_turn
  end

  test "review capture preserves scope and grants and restores context after errors" do
    @alice_inbox.update!(data: @alice_inbox.data.merge("ai_write_policy" => "review"))
    Collavre::CreativeShare.find_by!(creative: @bob_inbox, user: @agent).update!(permission: :admin)
    [ @alice_child, @bob_child ].each do |target|
      result = Collavre::Tools::CreativeBatchService.new.call(operations: [
        { "action" => "update", "id" => target.id, "description" => "Forbidden" },
        { "action" => "create", "parent_id" => @alice_inbox.id, "description" => "Draft child" }
      ])
      refute result[:success], result.inspect
      refute_equal "Forbidden", target.reload.description
      assert_nil Collavre::Current.draft_capture_turn
    end
    assert_empty Collavre::CreativeChangeSet.where(task: @task, status: "draft")
    original_turn = Collavre::Current.agent_turn
    assert_raises(RuntimeError) do
      Collavre::Creatives::DraftChangeSetCapture.new(anchor: @alice_inbox, origin: :tool).call do
        assert_nil Collavre::Current.agent_turn
        assert_same original_turn, Collavre::Current.draft_capture_turn
        assert @alice_child.has_permission?(@agent, :read)
        refute @bob_child.has_permission?(@agent, :read)
        raise "capture failed"
      end
    end
    assert_same original_turn, Collavre::Current.agent_turn
    assert_nil Collavre::Current.draft_capture_turn
  end

  test "search excludes other inbox descriptions and comments" do
    assert_equal [ @alice_child.id ], @retrieval.call(query: "shared-word").map { |row| row[:id] }
    assert_empty @retrieval.call(query: "private-search")
    assert_empty @retrieval.call(id: @bob_inbox.id, include_comments: true, format: "json")
    assert_equal [ @alice_inbox.id ], @retrieval.call(format: "json").map { |row| row[:id] }
  end

  test "markdown and json expansion reject links to foreign inboxes including agent-owned shells" do
    link = Collavre::Creative.create!(user: @agent, parent: @alice_inbox, origin: @bob_inbox)
    %w[markdown json].each do |format|
      result = @retrieval.call(id: @alice_inbox.id, level: 5, include_comments: true, format: format).to_s
      assert_includes result, "shared-word Alice"
      refute_includes result, "Bob secret"
      refute_includes result, "private-search"
    end
    refute link.has_permission?(@agent)
    refute_includes @alice_inbox.linked_children.map(&:id), link.id
  end

  test "multi-hop links cannot read or mutate an external origin" do
    inner = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, origin: @bob_child)
    outer = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, origin: inner)
    Collavre::CreativeSharesCache.find_by!(creative: inner, user: @agent).update!(permission: :admin)
    assert_equal @bob_child, outer.effective_origin
    assert_empty Collavre::Kollavy::AccessScope.filter([ inner.id, outer.id ])
    assert_empty @retrieval.call(id: outer.id, format: "json")
    assert Collavre::Tools::CreativeUpdateService.new.call(id: outer.id, description: "changed")[:error]
    assert_equal "shared-word Bob secret", @bob_child.reload.description
  end

  test "multi-hop links entirely within the tree remain in scope" do
    inner = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, origin: @alice_child)
    outer = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, origin: inner)
    assert_equal [ outer.id ], Collavre::Kollavy::AccessScope.filter([ outer.id ])
  end

  test "scope rejects an external intermediate hop even when the final origin is internal" do
    inner = Collavre::Creative.create!(user: @bob, parent: @bob_inbox, origin: @alice_child)
    outer = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, origin: inner)
    assert_empty Collavre::Kollavy::AccessScope.filter([ outer.id ])
  end

  test "scope rejects cyclic origin chains" do
    link = Collavre::Creative.create!(user: @alice, parent: @alice_inbox, origin: @alice_child)
    # Simulate corrupt legacy rows without model callbacks traversing the cycle.
    Collavre::Creative.where(id: link.id).update_all(origin_id: link.id)
    assert_empty Collavre::Kollavy::AccessScope.filter([ link.id ])
  end

  %w[reference configured].each do |source|
    test "#{source} prompt context respects an explicit no_access in the active tree" do
      Collavre::CreativeShare.create!(creative: @alice_child, user: @agent, permission: :no_access)
      refute @alice_child.has_permission?(@agent, :read)
      if source == "configured"
        @alice_inbox.update!(data: @alice_inbox.data.merge("context_ids" => [ @alice_child.id ]))
      end
      content = source == "reference" ? "Read [linked](/creatives/#{@alice_child.id})" : "hello"
      context = { "creative" => { "id" => @alice_inbox.id }, "comment" => { "content" => content } }
      messages = Collavre::AiAgent::MessageBuilder.new(agent: @agent, context: context, task: @task).build[:messages]
      refute_includes messages.to_s, "shared-word Alice"
      assert_empty messages.select { |message| [ :referenced_creative, :context_creative ].include?(message[:kind]) }
    end
  end

  test "attachments topics and schedules cannot read another inbox by id" do
    assert Collavre::Tools::CreativeListAttachmentsService.new.call(creative_id: @bob_inbox.id)[:error]
    topic_id = @bob_inbox.main_topic.id
    assert Collavre::Tools::TopicListService.new.call(topic_ids: topic_id)[:errors].any?
    messages = Collavre::Tools::TopicMessagesService.new.call(topic_ids: topic_id, format: "json")
    assert messages[:topics].first[:error]
    assert Collavre::Tools::CronListService.new.call(creative_id: @bob_inbox.id)[:error]
  end

  test "global cron listing excludes foreign inbox schedules" do
    cron = SolidQueue::RecurringTask.create!(
      key: "cron_#{@bob_inbox.id}_kollavy_scope", class_name: "Collavre::CronActionJob",
      schedule: "0 9 * * *", static: false,
      arguments: [ { creative_id: @bob_inbox.id, message: "Bob schedule secret" } ]
    )
    refute_includes Collavre::Tools::CronListService.new.call.to_s, "Bob schedule secret"
  ensure
    cron&.destroy!
  end

  test "missing and mismatched task context fail closed" do
    [ nil, { task: nil }, { task: Collavre::Task.new(agent: @alice, creative: @alice_inbox) },
      { task: Collavre::Task.new(agent: @agent) },
      { task: Collavre::Task.new(agent: @agent, creative_id: -1) } ].each do |context|
      Collavre::Current.agent_turn = context
      assert_empty @retrieval.call(query: "shared-word")
      assert_empty @retrieval.call(format: "json")
      refute @alice_inbox.has_permission?(@agent)
    end
  end

  test "switching turns does not retain the previous inbox scope" do
    task = Collavre::Task.create!(agent: @agent, creative: @bob_inbox, name: "Bob asks")
    Collavre::Creatives::AgentTurnHistory.call(@agent, @bob, task) do
      assert_equal [ @bob_child.id ], @retrieval.call(query: "shared-word").map { |row| row[:id] }
      refute @alice_inbox.has_permission?(@agent)
    end
    assert_equal [ @alice_child.id ], @retrieval.call(query: "shared-word").map { |row| row[:id] }
  end

  test "scope never grants write permission and blocks foreign mutations even when shared for write" do
    assert Collavre::Tools::CreativeCreateService.new.call(description: "No parent")[:error]
    assert Collavre::Tools::CreativeCreateService.new.call(description: "No write", parent_id: @alice_inbox.id)[:error]
    Collavre::CreativeSharesCache.find_by!(creative: @bob_inbox, user: @agent).update!(permission: :admin)
    assert Collavre::Tools::CreativeUpdateService.new.call(id: @bob_inbox.id, description: "changed")[:error]
    refute @bob_inbox.has_permission?(@agent, :admin)
  end

  test "agent ownership cannot bypass scope for topics or creatives" do
    private_creative = Collavre::Creative.create!(user: @agent, description: "Other task")
    refute private_creative.has_permission?(@agent)
    assert_raises(Collavre::Tools::PermissionDeniedError) do
      Collavre::Tools::TopicAuthorizer.authorize_creative!(private_creative, :read)
    end
    assert_raises(Collavre::Tools::PermissionDeniedError) do
      Collavre::Tools::TopicAuthorizer.authorize_read!(private_creative.main_topic)
    end
  end

  test "prompt references and configured contexts cannot inject another inbox" do
    @alice_inbox.update!(data: @alice_inbox.data.merge("context_ids" => [ @bob_inbox.id ]))
    comment = Collavre::Comment.create!(
      user: @alice, creative: @alice_inbox,
      content: "Read [linked](/creatives/#{@bob_inbox.id})", skip_dispatch: true
    )
    context = { "creative" => { "id" => @alice_inbox.id },
                "comment" => { "id" => comment.id, "content" => comment.content } }
    messages = Collavre::AiAgent::MessageBuilder.new(
      agent: @agent, context: context, original_comment: comment, task: @task
    ).build[:messages]
    assert_includes messages.to_s, "Alice"
    refute_includes messages.to_s, "Bob secret"
    refute_includes messages.to_s, "private-search"
    assert_empty messages.select { |message| [ :referenced_creative, :context_creative ].include?(message[:kind]) }
  end

  test "writes within the active tree still require and honor the agent's own grant" do
    Collavre::CreativeShare.find_by!(creative: @alice_inbox, user: @agent).update!(permission: :write)
    result = Collavre::Tools::CreativeCreateService.new.call(description: "Allowed", parent_id: @alice_inbox.id)
    assert result[:success], result.inspect
    assert_equal @alice_inbox.id, Collavre::Creative.find(result[:id]).parent_id
  end

  test "a task anchored at a link uses its origin tree" do
    link = Collavre::Creative.create!(user: @alice, origin: @alice_inbox)
    @task.update!(creative: link)
    assert_equal [ @alice_inbox.id ], @retrieval.call(format: "json").map { |row| row[:id] }
    assert_empty @retrieval.call(id: @bob_inbox.id, format: "json")
  end

  test "child conversations do not inject ancestor titles" do
    @alice_inbox.update!(description: "Ancestor private context")
    @task.update!(creative: @alice_child)
    context = { "creative" => { "id" => @alice_child.id }, "comment" => { "content" => "hello" } }
    messages = Collavre::AiAgent::MessageBuilder.new(agent: @agent, context: context, task: @task).build[:messages]
    assert_includes messages.to_s, "Alice"
    refute_includes messages.to_s, "Ancestor private context"
  end

  test "ordinary agents are not constrained by Kollavy's task" do
    @bob.update!(llm_vendor: "gemini", llm_model: "gemini-3.1-flash-lite")
    Collavre::Current.set(user: @bob, agent_turn: nil) do
      assert @bob_inbox.has_permission?(@bob)
      assert_equal [ @bob_child.id ], @retrieval.call(query: "shared-word").map { |row| row[:id] }
    end
  end

  test "humans and ordinary agents retain their normal permissions" do
    Collavre::Current.set(user: @bob) do
      assert @bob_inbox.has_permission?(@bob, :admin)
      assert_equal [ @bob_child.id ], @retrieval.call(query: "shared-word").map { |row| row[:id] }
      assert @alice_inbox.has_permission?(@agent), "off-turn permission checks used by seeding remain valid"
    end
  end
end
