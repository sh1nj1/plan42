require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "creating a comment notifies write-permission users not present" do
    creative = creatives(:tshirt)
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
    commenter = users(:two)
    writer = User.create!(email: "writer@example.com", password: "secret", name: "Writer")
    CreativeShare.create!(creative: creative, user: writer, permission: :write)

    assert_difference("InboxItem.count", 2) do
      Comment.create!(creative: creative, user: commenter, content: "hi")
    end

    [ creative.user, writer ].each do |recipient|
      item = InboxItem.where(owner: recipient).last
      assert_equal "inbox.comment_added", item.message_key
      assert_includes item.localized_message, commenter.name
    end
  end

  test "creating a comment does not notify write-permission users in chat" do
    creative = creatives(:tshirt)
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
    commenter = users(:two)
    writer = User.create!(email: "writer@example.com", password: "secret", name: "Writer")
    CreativeShare.create!(creative: creative, user: writer, permission: :write)

    CommentPresenceStore.add(creative.id, creative.user.id)
    CommentPresenceStore.add(creative.id, writer.id)

    assert_no_difference("InboxItem.count") do
      Comment.create!(creative: creative, user: commenter, content: "hi")
    end
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
  end
end
