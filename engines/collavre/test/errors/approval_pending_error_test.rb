# frozen_string_literal: true

require "test_helper"

class ApprovalPendingErrorTest < ActiveSupport::TestCase
  test "stores tool_call and task" do
    tool_call = OpenStruct.new(
      name: "test_tool",
      id: "call_123",
      arguments: { param: "value" }
    )
    task = OpenStruct.new(id: 42)

    error = Collavre::ApprovalPendingError.new(
      "Test error",
      tool_call: tool_call,
      task: task
    )

    assert_equal "Test error", error.message
    assert_equal "test_tool", error.tool_name
    assert_equal "call_123", error.tool_call_id
    assert_equal({ param: "value" }, error.tool_arguments)
  end

  test "handles hash-based tool_call" do
    tool_call = {
      "name" => "hash_tool",
      "id" => "call_456",
      "arguments" => { "key" => "val" }
    }

    error = Collavre::ApprovalPendingError.new(tool_call: tool_call)

    assert_equal "hash_tool", error.tool_name
    assert_equal "call_456", error.tool_call_id
    assert_equal({ "key" => "val" }, error.tool_arguments)
  end

  test "to_h returns structured data" do
    tool_call = OpenStruct.new(
      name: "my_tool",
      id: "call_789",
      arguments: { a: 1 }
    )
    task = OpenStruct.new(id: 99)

    error = Collavre::ApprovalPendingError.new(tool_call: tool_call, task: task)
    hash = error.to_h

    assert_equal "my_tool", hash[:tool_name]
    assert_equal "call_789", hash[:tool_call_id]
    assert_equal({ a: 1 }, hash[:arguments])
    assert_equal 99, hash[:task_id]
  end

  test "handles nil values gracefully" do
    error = Collavre::ApprovalPendingError.new

    assert_nil error.tool_name
    assert_nil error.tool_call_id
    assert_equal({}, error.tool_arguments)
  end
end
