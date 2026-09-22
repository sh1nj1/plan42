# frozen_string_literal: true

require "test_helper"

class ToolUsageTest < ActiveSupport::TestCase
  setup do
    @owner = users(:two)
    @requester = users(:three)
    @agent = Collavre::User.create!(email: "tool-usage-agent@example.com", name: "Tool Agent", password: TEST_PASSWORD,
      llm_vendor: "openai", llm_model: "test-model", system_prompt: "Help", created_by_id: @owner.id)
    @creative = Collavre::Creative.create!(description: "Tool usage", user: @owner)
    @comment = @creative.comments.create!(user: @requester, content: "Please help", skip_dispatch: true)
    @task = Collavre::Task.create!(name: "Tool usage test", agent: @agent, creative: @creative,
      topic_id: @comment.topic_id, trigger_event_payload: { "comment" => { "id" => @comment.id } })
  end

  def recorder(**options)
    Collavre::ToolUsage::Recorder.new(context: { task: @task, user: @agent }, source: "internal", **options)
  end

  test "recorder snapshots task attribution and shares the given execution" do
    collector = recorder(execution_id: "run-1")
    collector.record(tool_name: :creative_read, duration_ms: 12)
    collector.record(tool_name: "creative_read", succeeded: false)
    rows = Collavre::ToolUsage.order(:id).to_a
    assert_equal %w[run-1:internal:seq-1 run-1:internal:seq-2], rows.map(&:event_key)
    assert_equal [ true, false ], rows.map(&:succeeded)
    row = rows.first
    assert_equal [ "run-1", "creative_read", 12 ], [ row.execution_id, row.tool_name, row.duration_ms ]
    assert_equal [ @agent.id, @owner.id, @requester.id, "human" ], [ row.agent_id, row.owner_id, row.requester_id, row.requester_kind ]
    assert_equal [ @task.id, @creative.id, @comment.topic_id ], [ row.task_id, row.creative_id, row.topic_id ]
    assert_equal [ @requester.id ], Collavre::ToolUsage::Requester.where(tool_usage_id: row.id).pluck(:user_id)
  end

  test "a repeated call id is recorded once" do
    collector = recorder
    2.times { collector.record(tool_name: "cron_list", call_id: "call-1") }
    assert_equal 1, Collavre::ToolUsage.count
  end

  test "visibility follows owner and requester" do
    recorder.record(tool_name: "cron_list")
    outsider = Collavre::User.create!(email: "tool-outsider@example.com", name: "Outsider", password: TEST_PASSWORD)
    assert_empty Collavre::ToolUsage.visible_to(nil)
    assert_empty Collavre::ToolUsage.visible_to(outsider)
    assert_equal 1, Collavre::ToolUsage.visible_to(@owner).count
    assert_equal 1, Collavre::ToolUsage.visible_to(@requester).count
    outsider.stub(:system_admin?, true) { assert_equal 1, Collavre::ToolUsage.visible_to(outsider).count }
  end

  test "error hashes count as failures" do
    assert Collavre::ToolUsage.failed_result?({ error: "Creative not found" })
    assert Collavre::ToolUsage.failed_result?({ "error" => "boom" })
    refute Collavre::ToolUsage.failed_result?({ success: true, error: nil })
    refute Collavre::ToolUsage.failed_result?("error")
    assert Collavre::ToolUsage.failed_result?({ tool: { name: "cron_list" }, result: { error: "Creative not found" } })
    assert Collavre::ToolUsage.failed_result?({ "tool" => {}, "result" => { "error" => "boom" } })
    refute Collavre::ToolUsage.failed_result?({ tool: { name: "cron_list" }, result: { crons: [] } })
    refute Collavre::ToolUsage.failed_result?({ result: { error: "not a meta_tool wrapper" } })
  end

  test "mcp calls are attributed to the token owner and never break the call" do
    pair = Collavre::Current.set(user: @agent) do
      Collavre::ToolUsage::McpCall.track("cron_list") { [ { success: true }, {} ] }
    end
    assert_equal [ { success: true }, {} ], pair
    Collavre::Current.set(user: @requester) do
      assert_raises(RuntimeError) { Collavre::ToolUsage::McpCall.track("cron_list") { raise "boom" } }
      Collavre::ToolUsage::McpCall.track("topic_list") { [ { error: "denied" }, {} ] }
    end
    agent_row, raised_row, error_row = Collavre::ToolUsage.order(:id).to_a
    assert_equal [ "mcp", true, @agent.id, @owner.id, "unknown" ],
      [ agent_row.source, agent_row.succeeded, agent_row.agent_id, agent_row.owner_id, agent_row.requester_kind ]
    assert_equal [ false, nil, @requester.id ], [ raised_row.succeeded, raised_row.agent_id, raised_row.requester_id ]
    refute error_row.succeeded
    assert_operator agent_row.duration_ms, :>=, 0
    assert_not_equal agent_row.execution_id, raised_row.execution_id

    Collavre::ToolUsage::Recorder.stub(:new, ->(**) { raise "db down" }) do
      assert_equal [ 1, {} ], Collavre::ToolUsage::McpCall.track("cron_list") { [ 1, {} ] }
    end
  end

  test "mcp calls made with a workspace callback token are recorded and tagged with the workspace" do
    workspace = Struct.new(:id).new(42)
    pair = Collavre::Current.set(user: @requester, mcp_agent_workspace: workspace) do
      Collavre::ToolUsage::McpCall.track("cron_list", { creative_id: 5 }) { [ { success: true }, {} ] }
    end
    Collavre::Current.set(user: @requester) { Collavre::ToolUsage::McpCall.track("cron_list", { creative_id: 5 }) { [ {}, {} ] } }

    assert_equal [ { success: true }, {} ], pair
    tagged, untagged = Collavre::ToolUsage.order(:id).to_a
    assert_equal [ "mcp", 42, @requester.id ], [ tagged.source, tagged.agent_workspace_id, tagged.requester_id ]
    assert_equal Collavre::ToolUsage.arguments_digest("creative_id" => 5), tagged.arguments_digest
    assert_nil untagged.arguments_digest
  end

  test "arguments digest ignores key order and key type but not values" do
    digest = Collavre::ToolUsage.arguments_digest(b: [ { y: 1.0, x: "a" } ], a: nil)

    assert_equal digest, Collavre::ToolUsage.arguments_digest("a" => nil, "b" => [ { "x" => "a", "y" => 1 } ])
    refute_equal digest, Collavre::ToolUsage.arguments_digest("a" => nil, "b" => [ { "x" => "a", "y" => 1.5 } ])
    assert_nil Collavre::ToolUsage.arguments_digest("{\"a\"… [truncated 10 bytes]")
    assert_nil Collavre::ToolUsage.arguments_digest(nil)
  end

  test "the FastMcp tool entry point records one mcp call and the RubyLLM tool records none" do
    Collavre::Current.set(user: @requester) do
      result, = Mcp::CronList.new.call_with_schema_validation!(creative_id: 0)
      assert_equal "Creative not found", result[:error]
      Tools::CronList.new.call({})
    end
    row = Collavre::ToolUsage.sole
    assert_equal [ "mcp", "cron_list", false ], [ row.source, row.tool_name, row.succeeded ]
  end

  test "the FastMcp tool entry point digests the arguments of a workspace call" do
    Collavre::Current.set(user: @requester, mcp_agent_workspace: Struct.new(:id).new(42)) do
      Mcp::CronList.new.call_with_schema_validation!(creative_id: 0)
    end

    assert_equal Collavre::ToolUsage.arguments_digest("creative_id" => 0), Collavre::ToolUsage.sole.arguments_digest
  end

  test "report groups by tool name within range and filters" do
    collector = recorder(execution_id: "run-report")
    collector.record(tool_name: "cron_list", duration_ms: 10)
    collector.record(tool_name: "cron_list", succeeded: false, duration_ms: 30)
    collector.record(tool_name: "topic_list")
    Collavre::ToolUsage.create!(event_key: "old", execution_id: "old", source: "mcp", tool_name: "cron_list",
      requester_kind: "unknown", owner_id: @owner.id, occurred_at: 2.years.ago)
    Collavre::LlmUsage.create!(event_key: "run-report", execution_id: "run-report", owner_id: @owner.id,
      requester_kind: "unknown", vendor: "openai", model: "test", occurred_at: Time.current)

    rows = report.rows
    assert_equal [ { tool_name: "cron_list", calls: 2, failures: 1, average_duration_ms: 20 },
                   { tool_name: "topic_list", calls: 1, failures: 0, average_duration_ms: nil } ], rows
    assert_equal 2, report(requester_id: @requester.id, agent_id: @agent.id, owner_id: @owner.id).rows.size
    assert_equal 2, report(model: "test").rows.size
    assert_empty report(model: "other").rows
    assert_empty report(agent_id: @requester.id).rows
    assert_empty report(user: Collavre::User.create!(email: "tool-report-outsider@example.com", name: "O", password: TEST_PASSWORD)).rows
  end

  private

  def report(user: @owner, **params)
    range = Collavre::LlmUsage::Report.new(user: user).range
    Collavre::ToolUsage::Report.new(user: user, range: range, params: params)
  end
end
