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
