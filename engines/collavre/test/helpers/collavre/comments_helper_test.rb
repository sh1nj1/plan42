require "test_helper"

class Collavre::CommentsHelperTest < ActionView::TestCase
  include Collavre::CommentsHelper

  Stub = Struct.new(:action)

  test "comment_action_markdown returns markdown string when key present" do
    comment = Stub.new({ markdown: "# Hello", raw: { a: 1 } }.to_json)
    assert_equal "# Hello", comment_action_markdown(comment)
  end

  test "comment_action_markdown returns nil when markdown key absent" do
    comment = Stub.new({ tool: "foo", result: "bar" }.to_json)
    assert_nil comment_action_markdown(comment)
  end

  test "comment_action_markdown returns nil when markdown value is blank" do
    comment = Stub.new({ markdown: "" }.to_json)
    assert_nil comment_action_markdown(comment)
  end

  test "comment_action_markdown returns nil for invalid JSON" do
    comment = Stub.new("not json {")
    assert_nil comment_action_markdown(comment)
  end

  test "comment_action_markdown returns nil for non-Hash JSON" do
    comment = Stub.new([ "markdown", "value" ].to_json)
    assert_nil comment_action_markdown(comment)
  end

  test "comment_action_markdown returns nil when action is nil" do
    comment = Stub.new(nil)
    assert_nil comment_action_markdown(comment)
  end
end
