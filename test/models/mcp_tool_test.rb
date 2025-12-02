require "test_helper"

class McpToolTest < ActiveSupport::TestCase
  test "approve! registers tool via McpService" do
    creative = Creative.create!(user: users(:one), description: "Test")
    tool = McpTool.create!(creative: creative, name: "test_tool", source_code: "class Foo; end")

    mock_service = Minitest::Mock.new
    mock_service.expect :register_tool_from_source, nil, [ "class Foo; end" ]

    McpService.stub :register_tool_from_source, ->(s) { mock_service.register_tool_from_source(s) } do
      tool.approve!
    end

    mock_service.verify
    assert_not_nil tool.approved_at
  end

  test "approve! does not set approved_at if registration fails" do
    creative = Creative.create!(user: users(:one), description: "Test")
    tool = McpTool.create!(creative: creative, name: "fail_tool", source_code: "invalid")

    McpService.stub :register_tool_from_source, ->(_) { raise "Registration failed" } do
      assert_raises(RuntimeError) do
        tool.approve!
      end
    end

    tool.reload
    assert_nil tool.approved_at
  end

  test "destroy unregisters tool via McpService" do
    creative = Creative.create!(user: users(:one), description: "Test")
    tool = McpTool.create!(creative: creative, name: "test_tool", source_code: "class Foo; end")

    mock_service = Minitest::Mock.new
    mock_service.expect :delete_tool, nil, [ "test_tool" ]

    McpService.stub :delete_tool, ->(n) { mock_service.delete_tool(n) } do
      tool.destroy
    end

    mock_service.verify
  end
end
