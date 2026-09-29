require "test_helper"

class Collavre::Comments::ApprovedToolInvocationTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    @root = Collavre::Creative.inbox_for(@owner)
    @agent = Collavre::Kollavy.seed!
    @share = Collavre::CreativeShare.find_by!(creative: @root, user: @agent)
    @share.update!(permission: :write)
    @child = Collavre::Creative.create!(user: @owner, parent: @root, description: "Original")
    @destination = Collavre::Creative.create!(user: @owner, parent: @root, description: "Destination")
    Collavre::Creatives::PermissionCacheBuilder.rebuild_for_creative(@root)
    @task = Collavre::Task.create!(agent: @agent, creative: @root, status: "pending_approval", name: "Approve mutation",
      trigger_event_payload: { "workspace_user_id" => @owner.id })
  end

  teardown { Collavre::Current.reset }

  test "revoked conversation share blocks dispatch even if the target retains a grant" do
    Collavre::CreativeShare.create!(creative: @child, user: @agent, permission: :write)
    @share.delete
    assert_stale_write(@root)
    ::Tools::MetaToolService.stub(:new, -> { flunk "Revoked conversation must not dispatch" }) do
      assert invoke.key?(:error)
    end
    assert_equal "Original", @child.reload.description
  end

  %i[read feedback no_access].each do |permission|
    test "#{permission} downgrade blocks approved writes despite stale cached write permission" do
      @share.update_columns(permission: Collavre::CreativeShare.permissions[permission])
      assert_stale_write(@child)
      result = invoke
      assert result.key?(:error), result.inspect
      assert_equal "Original", @child.reload.description
    end
  end

  test "nested meta calls use current target shares instead of the task root grant" do
    share = Collavre::CreativeShare.create!(creative: @child, user: @agent, permission: :write)
    share.update_columns(permission: Collavre::CreativeShare.permissions[:read])
    assert_stale_write(@child)
    arguments = { action: "run", tool_name: "meta_tool", arguments: {
      action: "call", tool_name: "creative_update_service", arguments: { id: @child.id, description: "Changed" }
    } }
    result = invoke("meta_tool", arguments)
    assert result.key?(:error), result.inspect
    assert_equal "Original", @child.reload.description
  end

  test "move checks the current destination grant as well as the source" do
    share = Collavre::CreativeShare.create!(creative: @destination, user: @agent, permission: :write)
    share.update_columns(permission: Collavre::CreativeShare.permissions[:read])
    assert_stale_write(@destination)
    result = invoke("creative_update_service", { id: @child.id, parent_id: @destination.id })
    assert result.key?(:error), result.inspect
    assert_equal @root.id, @child.reload.parent_id
  end

  test "retained write and read grants allow the matching operation and restore context" do
    result = invoke
    refute result.key?(:error), result.inspect
    assert_includes @child.reload.description, "Changed"
    @share.update_columns(permission: Collavre::CreativeShare.permissions[:read])
    result = invoke("creative_retrieval_service", { id: @child.id, format: "json" })
    assert_equal @child.id, result.first[:id]
  end

  test "approval records a denied target result without executing the mutation" do
    arguments = { "id" => @child.id, "description" => "Changed" }
    @task.update!(pending_tool_call: {
      "tool_name" => "creative_update_service", "tool_call_id" => "approved-write", "arguments" => arguments
    })
    comment = @root.comments.create!(user: @agent, approver: @owner, content: "Approve write", action: {
      action: "execute_tool", tool_name: "creative_update_service", arguments: arguments,
      resume: { task_id: @task.id, tool_call_id: "approved-write" }
    }.to_json)
    @share.update_columns(permission: Collavre::CreativeShare.permissions[:read])
    assert_stale_write(@child)

    Collavre::AiAgentJob.stub(:perform_later, nil) do
      Collavre::Comments::ActionExecutor.new(comment: comment, executor: @owner).call
    end

    assert_equal "Original", @child.reload.description
    assert @task.reload.pending_tool_call.dig("result", "result", "error").present?
    assert_equal @owner, comment.reload.action_executed_by
    assert_nil Collavre::Current.authoritative_permissions
  end

  test "a tool failure restores the authorization mode and approver" do
    service = Object.new
    service.define_singleton_method(:call) { |**| raise "Tool failed" }
    ::Tools::MetaToolService.stub(:new, -> { service }) do
      assert_equal({ error: "Tool failed" }, invoke)
    end
  end

  private

  def invoke(tool = "creative_update_service", arguments = { id: @child.id, description: "Changed" })
    result = nil
    Collavre::Current.set(user: @owner) do
      result = Collavre::Comments::ApprovedToolInvocation.call(@task, tool, arguments)
      assert_equal @owner, Collavre::Current.user
      assert_nil Collavre::Current.authoritative_permissions
      assert_nil Collavre::Current.agent_turn
    end
    result = result[:result] while result.is_a?(Hash) && result.key?(:result)
    result
  end

  def assert_stale_write(creative)
    Collavre::Current.set(user: @agent, agent_turn: { task: @task, user: @owner }) do
      assert creative.has_permission?(@agent, :write), "The cache must still grant write access"
    end
  end
end
