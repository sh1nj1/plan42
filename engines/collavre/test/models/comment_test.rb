require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "creating a comment notifies write-permission users not present" do
    creative = creatives(:tshirt)
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
    commenter = users(:two)
    writer = User.create!(email: "writer@example.com", password: TEST_PASSWORD, name: "Writer")
    CreativeShare.create!(creative: creative, user: writer, permission: :write)

    comment = nil
    # Notifications now create comments on inbox creatives (one per recipient)
    assert_difference("Comment.count", 3) do # 1 original + 2 inbox comments
      comment = Comment.create!(creative: creative, user: commenter, content: "hi")
    end

    [ creative.user, writer ].each do |recipient|
      inbox = Creative.inbox_for(recipient)
      inbox_comment = inbox.comments.where(quoted_comment: comment).last
      assert inbox_comment, "Expected inbox comment for #{recipient.email}"
      assert_nil inbox_comment.user, "Inbox comment should be system (user: nil)"
      assert_equal comment.id, inbox_comment.quoted_comment_id
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

    # Only the original comment should be created, no inbox comments
    assert_difference("Comment.count", 1) do
      Comment.create!(creative: creative, user: commenter, content: "hi")
    end
    Rails.cache.delete(CommentPresenceStore.key(creative.id))
  end

  test "formats content before saving" do
    user = User.create!(email: "formatter@example.com", password: TEST_PASSWORD, name: "Formatter")
    creative = Creative.create!(user: user, description: "Root")

    formatter = Minitest::Mock.new
    formatter.expect(:format, "formatted content")

    Collavre::CommentLinkFormatter.stub(:new, formatter) do
      comment = Comment.create!(creative: creative, user: user, content: "https://example.com")
      assert_equal "formatted content", comment.content
    end

    formatter.verify
  end

  test "creates inbox comment for mentioned users" do
    owner = User.create!(email: "mentions-owner@example.com", password: TEST_PASSWORD, name: "Owner")
    commenter = User.create!(email: "mentions-commenter@example.com", password: TEST_PASSWORD, name: "Commenter")
    mentioned = User.create!(email: "mentions-mentioned@example.com", password: TEST_PASSWORD, name: "Mentioned", searchable: true)
    creative = Creative.create!(user: owner, description: "Root")

    inbox = Creative.inbox_for(mentioned)
    comment = nil
    assert_difference("inbox.comments.count", 1) do
      comment = Comment.create!(creative: creative, user: commenter, content: "hi @#{mentioned.name}:")
    end

    inbox_comment = inbox.comments.last
    assert_nil inbox_comment.user
    assert_equal comment.id, inbox_comment.quoted_comment_id
  end

  test "does not create duplicate mentions for existing recipient" do
    owner = User.create!(email: "mentions-owner-dup@example.com", password: TEST_PASSWORD, name: "OwnerDup")
    commenter = User.create!(email: "mentions-commenter-dup@example.com", password: TEST_PASSWORD, name: "CommenterDup")
    creative = Creative.create!(user: owner, description: "Root")

    inbox = Creative.inbox_for(owner)
    assert_difference("inbox.comments.count", 1) do
      Comment.create!(creative: creative, user: commenter, content: "hi @#{owner.name}:")
    end
  end

  test "defaults user to Current.user when user missing" do
    owner = User.create!(email: "comment-owner@example.com", password: TEST_PASSWORD, name: "Owner")
    current_user = User.create!(email: "comment-current@example.com", password: TEST_PASSWORD, name: "Current")
    Current.session = Struct.new(:user).new(current_user)
    creative = Creative.create!(user: owner, description: "Root")

    comment = Comment.create!(creative: creative, content: "hello")
    assert_equal current_user.id, comment.user.id
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

  test "streaming placeholder does not create inbox comments" do
    owner = users(:one)
    ai_agent = users(:ai_bot)

    perform_enqueued_jobs do
      creative = Creative.create!(user: owner, description: "Test inbox skip")
      CreativeShare.create!(creative: creative, user: ai_agent, permission: :feedback, shared_by: owner)
    end

    creative = Creative.last
    inbox = Creative.inbox_for(owner)
    initial_inbox_comment_count = inbox.comments.count

    perform_enqueued_jobs do
      creative.comments.create!(content: Collavre::Comment::STREAMING_PLACEHOLDER_CONTENT, user: ai_agent)
    end

    # No inbox comments should be created for "..." placeholder from AI agent
    assert_equal initial_inbox_comment_count, inbox.comments.count
  end

  test "creating an inbox notification broadcasts inbox badge immediately" do
    creative = creatives(:tshirt)
    commenter = users(:two)
    owner = creative.user
    inbox_creative = Creative.inbox_for(owner)

    broadcasts = []

    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kwargs) {
      broadcasts << { stream: args.first, target: kwargs[:target], locals: kwargs[:locals] }
    }) do
      perform_enqueued_jobs do
        Comment.create!(creative: creative, user: commenter, content: "immediate inbox badge")
      end
    end

    inbox_broadcasts = broadcasts.select { |payload| payload[:stream] == ["inbox", owner] }

    assert inbox_broadcasts.any?, "expected inbox badge broadcast"
    assert inbox_broadcasts.any? { |payload| payload[:target] == "desktop-inbox-badge" && payload.dig(:locals, :count) == 1 }
    assert inbox_broadcasts.any? { |payload| payload[:target] == "mobile-inbox-badge" && payload.dig(:locals, :count) == 1 }
    assert_equal 1, Collavre::Inbox::BadgeComponent.new(user: owner, creative: inbox_creative).count
  end
end
