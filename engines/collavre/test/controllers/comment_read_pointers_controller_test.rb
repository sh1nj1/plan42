require "test_helper"

class CommentReadPointersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    @creative = creatives(:tshirt)
  end

  test "updating pointer sets last_read_comment_id" do
    commenter = users(:two)

    comment_one = Comment.create!(creative: @creative, user: commenter, content: "hi there")
    comment_two = Comment.create!(creative: @creative, user: commenter, content: "hello again")

    post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin)
    assert_equal comment_two.id, pointer.last_read_comment_id
  end

  test "updating pointer broadcasts badge update" do
    commenter = users(:two)
    Comment.create!(creative: @creative, user: commenter, content: "hi there")

    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kwargs) {
      broadcasts << { stream: args.first, target: kwargs[:target], locals: kwargs[:locals] }
    }) do
      post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json
    end

    assert_response :success
    assert broadcasts.any? { |payload| payload.dig(:locals, :count) == 0 }, "expected badge update broadcast with zero unread"
  end

  test "updating a topic only marks that topic as read" do
    first_topic = @creative.main_topic
    second_topic = @creative.topics.create!(name: "Second", user: @user)
    Comment.create!(creative: @creative, topic: first_topic, user: users(:two), content: "first")
    unread = Comment.create!(creative: @creative, topic: second_topic, user: users(:two), content: "second")

    post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: first_topic.id }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: first_topic)
    assert_equal first_topic.comments.maximum(:id), pointer.last_read_comment_id
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: second_topic)

    counts = Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)
    assert_equal({ second_topic.id => 1 }, counts)
    assert_equal unread.id, second_topic.comments.maximum(:id)
  end

  test "All Messages leaves archived topic comments unread" do
    active_topic = @creative.topics.create!(name: "Active", user: @user)
    archived_topic = @creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
    archived = Comment.create!(creative: @creative, topic: archived_topic, user: users(:two), content: "archived")
    Comment.create!(creative: @creative, topic: active_topic, user: users(:two), content: "active")

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_ids: [ @creative.main_topic.id, active_topic.id ]
    }, as: :json

    assert_response :success
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: archived_topic)
    counts = Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)
    assert_equal({ archived_topic.id => 1 }, counts)
    assert_equal archived.id, archived_topic.comments.maximum(:id)
  end

  test "legacy creative-wide requests mark archived and topic-less comments as read" do
    archived_topic = @creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
    archived = Comment.create!(creative: @creative, topic: archived_topic, user: users(:two), content: "archived")
    legacy = Comment.create!(creative: @creative, user: users(:two), content: "legacy")
    legacy.update_column(:topic_id, nil)

    post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json

    assert_response :success
    assert_equal archived.id, CommentReadPointer.find_by!(user: @user, creative: @creative.effective_origin, topic: archived_topic).last_read_comment_id
    assert_equal legacy.id, CommentReadPointer.find_by!(user: @user, creative: @creative.effective_origin, topic: nil).last_read_comment_id
    assert_empty Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)
  end

  test "All Messages treats an explicitly empty rendered topic snapshot as authoritative" do
    active_topic = @creative.topics.create!(name: "Active", user: @user)
    unseen = Comment.create!(creative: @creative, topic: active_topic, user: users(:two), content: "arrived after empty list")

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_ids: [],
      topic_watermarks: {}
    }, as: :json

    assert_response :success
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: active_topic)
    assert_equal({ active_topic.id => 1 }, Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative))
    assert_equal unseen.id, active_topic.comments.maximum(:id)
  end

  test "All Messages does not mark a topic unarchived after the list rendered as read" do
    active_topic = @creative.topics.create!(name: "Active", user: @user)
    newly_unarchived_topic = @creative.topics.create!(name: "Later", user: @user, archived_at: Time.current)
    unread = Comment.create!(creative: @creative, topic: newly_unarchived_topic, user: users(:two), content: "history")
    newly_unarchived_topic.update!(archived_at: nil)

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_ids: [ @creative.main_topic.id, active_topic.id ]
    }, as: :json

    assert_response :success
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: newly_unarchived_topic)
    counts = Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)
    assert_equal({ newly_unarchived_topic.id => 1 }, counts)
    assert_equal unread.id, newly_unarchived_topic.comments.maximum(:id)
  end

  test "All Messages does not mark a comment added after a rendered topic is archived as read" do
    topic = @creative.topics.create!(name: "Later archived", user: @user)
    rendered = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "rendered")
    topic.update!(archived_at: Time.current)
    hidden = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "hidden")

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_ids: [ topic.id ],
      topic_watermarks: { topic.id => rendered.id }
    }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by!(user: @user, creative: @creative.effective_origin, topic: topic)
    assert_equal rendered.id, pointer.last_read_comment_id
    assert_equal({ topic.id => 1 }, Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative))
    assert_equal hidden.id, topic.comments.maximum(:id)
  end

  test "All Messages never moves an existing topic pointer backwards" do
    topic = @creative.topics.create!(name: "Concurrent", user: @user)
    rendered = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "rendered")
    newer = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "newer")
    CommentReadPointer.create!(user: @user, creative: @creative.effective_origin, topic: topic, last_read_comment_id: newer.id)

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_ids: [ topic.id ],
      topic_watermarks: { topic.id => rendered.id }
    }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by!(user: @user, creative: @creative.effective_origin, topic: topic)
    assert_equal newer.id, pointer.last_read_comment_id
  end

  test "All Messages records a bounded legacy topic-less read" do
    legacy = Comment.create!(creative: @creative, user: users(:two), content: "legacy")
    legacy.update_column(:topic_id, nil)

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_watermarks: { "_legacy" => legacy.id }
    }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by!(user: @user, creative: @creative.effective_origin, topic: nil)
    assert_equal legacy.id, pointer.last_read_comment_id
  end

  test "advancing the legacy lane preserves unread named topics omitted from All Messages" do
    archived_topic = @creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
    unseen = Comment.create!(creative: @creative, topic: archived_topic, user: users(:two), content: "unseen")
    legacy = Comment.create!(creative: @creative, user: users(:two), content: "rendered legacy")
    legacy.update_column(:topic_id, nil)

    post "/comment_read_pointers/update", params: {
      creative_id: @creative.id,
      topic_watermarks: { "_legacy" => legacy.id }
    }, as: :json

    assert_response :success
    named_pointer = CommentReadPointer.find_by!(user: @user, creative: @creative.effective_origin, topic: archived_topic)
    assert_nil named_pointer.last_read_comment_id
    assert_equal({ archived_topic.id => 1 }, Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative))
    assert_equal unseen.id, archived_topic.comments.maximum(:id)
  end

  test "topic read receipt broadcasts exclude readers whose access was revoked" do
    topic = @creative.main_topic
    comment = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "public")
    revoked_reader = User.create!(email: "revoked-reader@example.test", password: "password", name: "Revoked reader")
    CommentReadPointer.create!(user: revoked_reader, creative: @creative, topic: topic, last_read_comment: comment)

    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_update_to, ->(*args, **kwargs) { broadcasts << kwargs }) do
      post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: topic.id }, as: :json
    end

    assert_response :success
    read_by_users = broadcasts.last.fetch(:locals).fetch(:read_by_users)
    refute_includes read_by_users, revoked_reader
  end

  test "topic read receipt broadcasts include legacy fallback readers" do
    topic = @creative.main_topic
    comment = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "public")
    legacy_reader = User.create!(email: "legacy-reader@example.test", password: "password", name: "Legacy reader")
    CreativeShare.create!(creative: @creative, user: legacy_reader, shared_by: @user, permission: :read)
    CommentReadPointer.create!(user: legacy_reader, creative: @creative, last_read_comment: comment)

    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_update_to, ->(*args, **kwargs) { broadcasts << kwargs }) do
      post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: topic.id }, as: :json
    end

    assert_response :success
    read_by_users = broadcasts.last.fetch(:locals).fetch(:read_by_users)
    assert_includes read_by_users, legacy_reader
  end

  test "creating a named pointer refreshes the receipt previously shown from the legacy fallback" do
    topic = @creative.main_topic
    first = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "first")
    second = Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "second")
    CommentReadPointer.create!(user: @user, creative: @creative, last_read_comment: first)

    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_update_to, ->(*args, **kwargs) { broadcasts << kwargs }) do
      post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: topic.id }, as: :json
    end

    assert_response :success
    assert broadcasts.any? { |broadcast| broadcast[:target] == "read_receipts_comment_#{first.id}" },
      "expected the legacy fallback receipt to be replaced"
    assert_equal [ @user ], broadcasts.last.fetch(:locals).fetch(:read_by_users)
    assert_equal "read_receipts_comment_#{second.id}", broadcasts.last.fetch(:target)
  end

  test "rejects a topic from another creative" do
    foreign_topic = Creative.create!(user: @user, description: "Foreign").main_topic

    post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: foreign_topic.id }, as: :json

    assert_response :unprocessable_entity
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative)
  end
end
