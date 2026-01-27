require "test_helper"

class McpServiceFilterTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @other_user = users(:two)
    @creative = Creative.create!(user: @user, description: "Tool Owner")

    # Mock tool objects (structs responding to tool_name)
    @system_tool = OpenStruct.new(tool_name: "system_tool")
    @user_tool = OpenStruct.new(tool_name: "user_tool")
    @other_tool = OpenStruct.new(tool_name: "other_tool")

    # Register dynamic tools in DB
    McpTool.create!(creative: @creative, name: "user_tool", source_code: "foo", approved_at: Time.current)
    McpTool.create!(creative: Creative.create!(user: @other_user, description: "Other"), name: "other_tool", source_code: "bar", approved_at: Time.current)
  end

  test "filters tools correctly for owner" do
    all_tools = [ @system_tool, @user_tool, @other_tool ]

    filtered = McpService.filter_tools(all_tools, @user)

    assert_includes filtered, @system_tool
    assert_includes filtered, @user_tool
    refute_includes filtered, @other_tool
  end

  test "filters tools correctly for other user" do
    all_tools = [ @system_tool, @user_tool, @other_tool ]

    filtered = McpService.filter_tools(all_tools, @other_user)

    assert_includes filtered, @system_tool
    refute_includes filtered, @user_tool
    assert_includes filtered, @other_tool
  end

  test "filters tools correctly for nil user (only system)" do
    all_tools = [ @system_tool, @user_tool, @other_tool ]

    filtered = McpService.filter_tools(all_tools, nil)

    assert_includes filtered, @system_tool
    refute_includes filtered, @user_tool
    refute_includes filtered, @other_tool
  end

  test "filters hash tools correctly" do
    system_hash = { name: "system_tool" }
    user_hash = { name: "user_tool" }
    other_hash = { name: "other_tool" }
    all_tools = [ system_hash, user_hash, other_hash ]

    filtered = McpService.filter_tools(all_tools, @user)

    assert_includes filtered, system_hash
    assert_includes filtered, user_hash
    refute_includes filtered, other_hash
  end

  test "filters string-keyed hash tools correctly" do
    system_hash = { "name" => "system_tool" }
    user_hash = { "name" => "user_tool" }
    other_hash = { "name" => "other_tool" }
    all_tools = [ system_hash, user_hash, other_hash ]

    filtered = McpService.filter_tools(all_tools, @user)

    assert_includes filtered, system_hash
    assert_includes filtered, user_hash
    refute_includes filtered, other_hash
  end

  test "filters hash tools correctly for nil user" do
    system_hash = { name: "system_tool" }
    user_hash = { name: "user_tool" }
    all_tools = [ system_hash, user_hash ]

    filtered = McpService.filter_tools(all_tools, nil)

    assert_includes filtered, system_hash
    refute_includes filtered, user_hash
  end
end
