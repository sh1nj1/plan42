require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "creating a comment notifies creative owner" do
    creative = creatives(:tshirt)
    commenter = users(:two)

    assert_difference("InboxItem.count", 1) do
      Comment.create!(creative: creative, user: commenter, content: "hi")
    end

    item = InboxItem.last
    assert_equal creative.user, item.owner
    assert_includes item.message, commenter.email
  end
end

