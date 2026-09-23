# frozen_string_literal: true

require "test_helper"

class CreativeToolAuthoringTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    Current.user = @owner
    @parent = Creative.create!(user: @owner, description: "Tool collection")
    @meta = Tools::MetaToolService.new
    guide = Rails.root.join("skills/collavre/references/tool-authoring.md").read
    @request = JSON.parse(guide.scan(/```json\n(.*?)\n```/m).first.first, symbolize_names: true)
    @request[:arguments][:parent_id] = @parent.id
    @name = "creative_greeting"
  end

  teardown do
    McpService.delete_tool(@name)
    McpService.delete_tool("creative_greeting_renamed")
    Current.reset
  end

  test "documented meta create, owner approval, schema and execution work end to end" do
    creative = create_tool
    tool = creative.mcp_tools.sole
    assert_not tool.active?
    assert_nil @meta.find_schema(@name)
    assert @meta.call(action: "run", tool_name: @name, arguments: { name: "Soonoh" })[:error]
    approve(creative)
    assert tool.reload.active?
    schema = @meta.call(action: "get", tool_name: @name).fetch(:tool)
    assert_equal @name, schema[:name]
    assert_equal :name, schema[:params].sole[:name]
    assert_equal({ name: "Soonoh" }, run_tool)
  end

  test "source update revokes execution until the new version is approved" do
    creative = create_tool
    approve(creative)
    update_tool(creative, markdown.sub("{ name: name }", "{ name: name.upcase }"))
    assert_not creative.mcp_tools.sole.active?
    assert @meta.call(action: "get", tool_name: @name)[:error]
    approve(creative)
    assert_equal({ name: "SOONOH" }, run_tool)
  end

  test "same source is idempotent and removal or rename unregisters the old name" do
    creative = create_tool
    approve(creative)
    approval_count = creative.comments.where.not(action: nil).count
    update_tool(creative, markdown)
    assert creative.mcp_tools.sole.active?
    assert_equal approval_count, creative.comments.where.not(action: nil).count
    update_tool(creative, markdown.gsub(@name, "creative_greeting_renamed"))
    assert @meta.call(action: "get", tool_name: @name)[:error]
    assert_equal "creative_greeting_renamed", creative.mcp_tools.sole.name
    update_tool(creative, "Tool removed")
    assert_empty creative.mcp_tools.reload
  end

  test "another user cannot discover or execute an approved tool through meta" do
    creative = create_tool
    approve(creative)
    Current.user = users(:two)
    %w[list list_summary search].each do |action|
      names = @meta.call(action: action, query: @name).fetch(:tools).map { |tool| tool[:name] }
      assert_not_includes names, @name
      assert_includes names, "meta_tool" unless action == "search"
    end
    assert @meta.call(action: "get", tool_name: @name)[:error]
    assert @meta.call(action: "run", tool_name: @name, arguments: { name: "Soonoh" })[:error]
    assert @meta.call(action: "run", tool_name: "creative_update_service", arguments: { id: creative.id, description: "Changed" }).dig(:result, :error)
    assert @meta.call(action: "run", tool_name: "creative_create_service", arguments: { parent_id: @parent.id, description: markdown }).dig(:result, :error)
  end

  test "only owner can approve the tool and rejected approval does not register it" do
    creative = create_tool
    assert_raises(Collavre::Comments::ActionExecutor::ExecutionError) do
      Collavre::Comments::ActionExecutor.new(comment: approval(creative), executor: users(:two)).call
    end
    assert_not creative.mcp_tools.sole.active?
    assert_nil @meta.find_schema(@name)
  end

  test "missing signature and malformed Ruby fail approval without registration" do
    [ markdown.sub(/  sig.*\n/, ""), markdown.sub("def call(name:)", "def call(name:") ].each do |body|
      creative = create_tool(body)
      assert_raises(Collavre::Comments::ActionExecutor::ExecutionError) { approve(creative) }
      assert_not creative.mcp_tools.sole.active?
      assert_nil @meta.find_schema(@name)
      creative.destroy!
    end
  end

  test "fresh worker reloads approved source and reconciles changes from another worker" do
    creative = create_tool
    approve(creative)
    McpService.delete_tool(@name)
    assert_equal({ name: "Soonoh" }, run_tool)
    tool = creative.mcp_tools.sole
    # Database-only writes model changes committed by a different process whose
    # registry is separate from this one.
    tool.update_columns(source_code: tool.source_code.sub("{ name: name }", "{ name: name.upcase }"))
    assert_equal({ name: "SOONOH" }, run_tool)
    tool.update_columns(approved_at: nil)
    assert @meta.call(action: "run", tool_name: @name, arguments: { name: "Soonoh" })[:error]
    assert_nil @meta.find_schema(@name)
  end

  test "deletion in another worker cannot turn a leftover tool into a system tool" do
    creative = create_tool
    approve(creative)
    creative.mcp_tools.delete_all
    assert @meta.call(action: "run", tool_name: @name, arguments: { name: "Soonoh" })[:error]
    assert_nil @meta.find_schema(@name)
  end

  test "blank descriptions remove previously extracted tools" do
    creative = create_tool
    approve(creative)
    creative.update_columns(description: "")
    McpService.new.update_from_creative(creative)
    assert_empty creative.mcp_tools.reload
    assert_nil @meta.find_schema(@name)
  end

  test "review policy keeps the source draft separate from executable approval" do
    @parent.update!(data: { "ai_write_policy" => "review" })
    result = Current.set(mcp_request: true) { @meta.call(**@request).fetch(:result) }
    assert result[:pending_review], result.inspect
    assert_not McpTool.exists?(name: @name)
    assert_nil @meta.find_schema(@name)
    change_set = Collavre::CreativeChangeSet.find(result[:change_set_id])
    perform_enqueued_jobs(only: Collavre::UpdateMcpToolsJob) do
      applied = Collavre::Creatives::ChangeSetApplyService.new(source: change_set, user: @owner, mode: :draft).call
      assert_equal :applied, applied.status
    end
    tool = McpTool.find_by!(name: @name)
    assert_not tool.active?
    assert_nil @meta.find_schema(@name)
    approve(tool.creative)
    assert_equal({ name: "Soonoh" }, run_tool)
  end

  test "duplicate tool names and service classes do not replace an existing tool" do
    creative = create_tool
    approve(creative)
    duplicate = create_tool
    assert_empty duplicate.mcp_tools
    other = create_tool(markdown.gsub(@name, "creative_greeting_renamed"))
    assert_raises(Collavre::Comments::ActionExecutor::ExecutionError) { approve(other) }
    assert_not other.mcp_tools.sole.active?
    assert_equal({ name: "Soonoh" }, run_tool)
  end

  test "creative deletion unregisters its tool" do
    creative = create_tool
    approve(creative)
    creative.destroy!
    assert @meta.call(action: "get", tool_name: @name)[:error]
  end

  test "one broken approved source does not prevent lazy loading other tools" do
    creative = create_tool
    approve(creative)
    McpService.delete_tool(@name)
    McpTool.create!(creative: @parent, name: "broken_authoring", source_code: "broken source", approved_at: Time.current)
    assert_equal({ name: "Soonoh" }, run_tool)
    assert @meta.call(action: "get", tool_name: "broken_authoring")[:error]
  end

  test "anonymous and read-only users cannot execute while a writer can" do
    creative = create_tool
    approve(creative)
    Current.user = nil
    assert @meta.call(action: "run", tool_name: @name, arguments: { name: "Soonoh" })[:error]
    reader = users(:two)
    share = nil
    perform_enqueued_jobs(only: Collavre::PermissionCacheJob) do
      share = CreativeShare.create!(creative: creative, user: reader, permission: :read)
    end
    Current.user = reader
    assert @meta.call(action: "get", tool_name: @name)[:error]
    perform_enqueued_jobs(only: Collavre::PermissionCacheJob) { share.update!(permission: :write) }
    assert_equal({ name: "Soonoh" }, run_tool)
  end

  test "tool execution does not hold the registry lock while waiting on external work" do
    body = markdown.sub("{ name: name }", "{ name: Collavre::McpToolRegistrar::REGISTRY_LOCK.mon_owned?.to_s }")
    creative = create_tool(body)
    approve(creative)
    assert_equal({ name: "false" }, run_tool)
  end

  test "skill copies and the executable example are identical" do
    %w[SKILL.md references/tool-authoring.md references/tool-reference.md].each do |path|
      assert_equal Rails.root.join("skills/collavre", path).read,
                   Rails.root.join("engines/collavre/skills/collavre", path).read
    end
  end

  private

  def markdown
    @request[:arguments][:description]
  end

  def create_tool(body = markdown)
    result = nil
    perform_enqueued_jobs(only: Collavre::UpdateMcpToolsJob) do
      result = @meta.call(**@request.merge(arguments: @request[:arguments].merge(description: body))).fetch(:result)
    end
    assert result[:success], result.inspect
    Creative.find(result[:id])
  end

  def update_tool(creative, body)
    perform_enqueued_jobs(only: Collavre::UpdateMcpToolsJob) do
      result = @meta.call(action: "run", tool_name: "creative_update_service", arguments: { id: creative.id, description: body })
      assert result.dig(:result, :success), result.inspect
    end
  end

  def approval(creative)
    creative.comments.where.not(action: nil).order(:id).last
  end

  def approve(creative)
    comment = approval(creative)
    assert_equal @owner, comment.approver
    Collavre::Comments::ActionExecutor.new(comment: comment, executor: @owner).call
  end

  def run_tool
    @meta.call(action: "run", tool_name: @name, arguments: { name: "Soonoh" }).fetch(:result)
  end
end
