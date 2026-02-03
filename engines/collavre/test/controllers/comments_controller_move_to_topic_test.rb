# frozen_string_literal: true

require "test_helper"

class CommentsControllerMoveToTopicTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)

    # Create topics
    @topic1 = Topic.create!(name: "Topic 1", creative: @creative, user: @user)
    @topic2 = Topic.create!(name: "Topic 2", creative: @creative, user: @user)

    # Create comments in Main (no topic)
    @comment1 = @creative.comments.create!(content: "Comment 1", user: @user, topic_id: nil)
    @comment2 = @creative.comments.create!(content: "Comment 2", user: @user, topic_id: nil)

    post session_path, params: { email: @user.email, password: "password" }
  end

  test "move comments to topic" do
    post move_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id, @comment2.id ], target_topic_id: @topic1.id },
         as: :json

    assert_response :success

    @comment1.reload
    @comment2.reload

    assert_equal @topic1.id, @comment1.topic_id
    assert_equal @topic1.id, @comment2.topic_id
  end

  test "move comments to Main (empty topic_id)" do
    # First move to topic
    @comment1.update!(topic_id: @topic1.id)
    @comment2.update!(topic_id: @topic1.id)

    # Then move back to Main
    post move_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id, @comment2.id ], target_topic_id: "" },
         as: :json

    assert_response :success

    @comment1.reload
    @comment2.reload

    assert_nil @comment1.topic_id
    assert_nil @comment2.topic_id
  end

  test "move comments to different topic" do
    @comment1.update!(topic_id: @topic1.id)

    post move_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id ], target_topic_id: @topic2.id },
         as: :json

    assert_response :success

    @comment1.reload
    assert_equal @topic2.id, @comment1.topic_id
  end

  test "returns error for invalid topic" do
    post move_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id ], target_topic_id: 99999 },
         as: :json

    assert_response :unprocessable_entity
  end

  test "skips comments already in target topic" do
    @comment1.update!(topic_id: @topic1.id)

    post move_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id ], target_topic_id: @topic1.id },
         as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 0, json["moved_count"]
  end
end
