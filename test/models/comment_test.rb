require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "creating a comment notifies write-permission users not present" do
    creative = creatives(:tshirt)
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
    commenter = users(:two)
    writer = User.create!(email: "writer@example.com", password: TEST_PASSWORD, name: "Writer")
    CreativeShare.create!(creative: creative, user: writer, permission: :write)

    comment = nil
    assert_difference("InboxItem.count", 2) do
      comment = Comment.create!(creative: creative, user: commenter, content: "hi")
    end

    origin = creative.effective_origin

    [ creative.user, writer ].each do |recipient|
      item = InboxItem.where(owner: recipient).last
      assert_equal "inbox.comment_added", item.message_key
      assert_includes item.localized_message, commenter.name
      assert_includes item.localized_message, ActionController::Base.helpers.strip_tags(creative.description)
      assert_equal comment, item.comment
      assert_equal origin, item.creative
      assert_equal comment.id, item.message_params["comment_id"]
      assert_equal origin.id, item.message_params["creative_id"]
    end
  end

  test "creating a comment does not notify write-permission users in chat" do
    creative = creatives(:tshirt)
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
    commenter = users(:two)
    writer = User.create!(email: "writer@example.com", password: TEST_PASSWORD, name: "Writer")
    CreativeShare.create!(creative: creative, user: writer, permission: :write)

    CommentPresenceStore.add(creative.id, creative.user.id)
    CommentPresenceStore.add(creative.id, writer.id)

    assert_no_difference("InboxItem.count") do
      Comment.create!(creative: creative, user: commenter, content: "hi")
    end
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
  end

  test "formats content before saving" do
    user = User.create!(email: "formatter@example.com", password: TEST_PASSWORD, name: "Formatter")
    creative = Creative.create!(user: user, description: "Root")

    formatter = Minitest::Mock.new
    formatter.expect(:format, "formatted content")

    CommentLinkFormatter.stub(:new, formatter) do
      comment = Comment.create!(creative: creative, user: user, content: "https://example.com")
      assert_equal "formatted content", comment.content
    end

    formatter.verify
  end

  test "creates a single inbox item for mentioned users" do
    owner = User.create!(email: "mentions-owner@example.com", password: TEST_PASSWORD, name: "Owner")
    commenter = User.create!(email: "mentions-commenter@example.com", password: TEST_PASSWORD, name: "Commenter")
    mentioned = User.create!(email: "mentions-mentioned@example.com", password: TEST_PASSWORD, name: "Mentioned", searchable: true)
    creative = Creative.create!(user: owner, description: "Root")

    comment = nil
    assert_difference("InboxItem.where(owner: mentioned).count", 1) do
      comment = Comment.create!(creative: creative, user: commenter, content: "hi @#{mentioned.name}:")
    end

    item = InboxItem.where(owner: mentioned).last
    assert_equal "inbox.user_mentioned", item.message_key
    assert_includes item.localized_message, commenter.name
    assert_equal comment, item.comment
    assert_equal creative.effective_origin, item.creative
    assert_equal comment.id, item.message_params["comment_id"]
    assert_equal creative.effective_origin.id, item.message_params["creative_id"]
  end

  test "does not create duplicate mentions for existing recipient" do
    owner = User.create!(email: "mentions-owner-dup@example.com", password: TEST_PASSWORD, name: "OwnerDup")
    commenter = User.create!(email: "mentions-commenter-dup@example.com", password: TEST_PASSWORD, name: "CommenterDup")
    creative = Creative.create!(user: owner, description: "Root")

    assert_difference("InboxItem.where(owner: owner).count", 1) do
      Comment.create!(creative: creative, user: commenter, content: "hi @#{owner.name}:")
    end

    items = InboxItem.where(owner: owner)
    assert_equal "inbox.user_mentioned", items.last.message_key
  end

  test "defaults user to Current.user when user missing" do
    owner = User.create!(email: "comment-owner@example.com", password: TEST_PASSWORD, name: "Owner")
    current_user = User.create!(email: "comment-current@example.com", password: TEST_PASSWORD, name: "Current")
    Current.session = Struct.new(:user).new(current_user)
    creative = Creative.create!(user: owner, description: "Root")

    comment = Comment.create!(creative: creative, content: "hello")
    assert_equal current_user, comment.user
  ensure
    Current.reset
  end

  test "moves comments on linked creatives to the origin" do
    owner = users(:one)
    viewer = users(:two)
    origin = Creative.create!(user: owner, description: "Origin Creative")
    linked = Creative.create!(user: viewer, origin: origin)

    comment = linked.comments.create!(user: viewer, content: "hello from linked")

    assert_equal origin, comment.creative
  end
end
