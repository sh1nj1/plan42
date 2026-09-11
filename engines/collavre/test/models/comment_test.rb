require "test_helper"

class CommentTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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
      expected_path = Collavre::Engine.routes.url_helpers.creative_path(creative, comment_id: comment.id)
      assert_includes inbox_comment.content, "(#{expected_path})"
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

  test "saves content immediately and enqueues link preview formatting" do
    user = User.create!(email: "formatter@example.com", password: TEST_PASSWORD, name: "Formatter")
    creative = Creative.create!(user: user, description: "Root")

    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    comment = Comment.create!(creative: creative, user: user, content: "https://example.com")

    assert_equal "https://example.com", comment.content
    assert_enqueued_with(
      job: Collavre::CommentLinkPreviewJob,
      args: [ comment.id, "https://example.com", comment.notification_revision ]
    )
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  test "enqueues inbox notifications instead of creating them during comment save" do
    creative = creatives(:tshirt)
    commenter = users(:two)
    inbox = Creative.inbox_for(creative.user)
    original_count = inbox.comments.count

    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    comment = Comment.create!(creative: creative, user: commenter, content: "async notification")

    assert_enqueued_with(
      job: Collavre::CommentNotificationJob,
      args: [ comment.id, "created", comment.notification_event ]
    )
    assert_equal original_count, inbox.comments.count
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
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

  test "rejects a stale topic membership after the topic moves" do
    owner = users(:one)
    source = Creative.create!(user: owner, description: "Comment source")
    destination = Creative.create!(user: owner, description: "Comment destination")
    topic = source.topics.create!(name: "Moving topic", user: owner)
    comment = source.comments.build(user: owner, topic: topic, content: "Late comment")

    Collavre::Topics::TopicMove.new(topic: topic, target_creative: destination).call

    assert_no_difference("Comment.count") { assert_not comment.save }
    assert_includes comment.errors[:topic], I18n.t("collavre.comments.invalid_topic")
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

  # Only the inbox System topic (alarms/notifications) is silenced; every other
  # inbox topic dispatches like a normal topic (see comment_inbox_dispatch_test).
  test "inbox System-topic comments do not dispatch to orchestration" do
    owner = User.create!(email: "inbox-orch-owner@example.com", password: TEST_PASSWORD, name: "InboxOrchOwner")
    commenter = User.create!(email: "inbox-orch-commenter@example.com", password: TEST_PASSWORD, name: "InboxOrchCommenter")
    inbox = Creative.inbox_for(owner)
    system_topic = inbox.system_topic(fallback_user: owner)

    dispatched = false
    SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true }) do
      inbox.comments.create!(user: commenter, content: "alarm note", topic: system_topic)
    end

    refute dispatched, "Expected no orchestration dispatch for inbox System-topic comments"
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

    inbox_broadcasts = broadcasts.select { |payload| payload[:stream] == [ "inbox", owner ] }

    assert inbox_broadcasts.any?, "expected inbox badge broadcast"
    assert inbox_broadcasts.any? { |payload| payload[:target] == "desktop-inbox-badge" && payload.dig(:locals, :count) == 1 }
    assert inbox_broadcasts.any? { |payload| payload[:target] == "mobile-inbox-badge" && payload.dig(:locals, :count) == 1 }
    assert_equal 1, Collavre::Inbox::BadgeComponent.new(user: owner, creative: inbox_creative).count
  end

  test "inbox badge without an inbox creative has no unread count" do
    assert_equal 0, Collavre::Inbox::BadgeComponent.new(user: users(:one)).count
  end

  test "creating and destroying a comment maintains creatives.comments_count" do
    user = User.create!(email: "cc-counter@example.com", password: TEST_PASSWORD, name: "CC")
    creative = Creative.create!(user: user, description: "Root")
    assert_equal 0, creative.comments_count

    c1 = Comment.create!(creative: creative, user: user, content: "one")
    Comment.create!(creative: creative, user: user, content: "two", private: true)
    assert_equal 2, creative.reload.comments_count, "counts all comments incl. private"

    c1.destroy!
    assert_equal 1, creative.reload.comments_count
  end

  test "creating and destroying versions maintains comment_versions_count" do
    user = User.create!(email: "cv-counter@example.com", password: TEST_PASSWORD, name: "CV")
    creative = Creative.create!(user: user, description: "Root")
    comment = Comment.create!(creative: creative, user: user, content: "hi")
    assert_equal 0, comment.comment_versions_count

    v1 = Collavre::CommentVersion.create!(comment: comment, content: "v1", version_number: 1)
    Collavre::CommentVersion.create!(comment: comment, content: "v2", version_number: 2)
    assert_equal 2, comment.reload.comment_versions_count

    v1.destroy!
    assert_equal 1, comment.reload.comment_versions_count
  end
end
