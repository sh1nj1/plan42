# frozen_string_literal: true

require "test_helper"

class CommentsControllerBranchTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)

    @topic = Topic.create!(name: "Original", creative: @creative, user: @user)
    @comment1 = @creative.comments.create!(content: "Hello", user: @user, topic: @topic)
    @comment2 = @creative.comments.create!(content: "World", user: @user, topic: @topic)

    post session_path, params: { email: @user.email, password: "password" }
  end

  test "branch comments into new topic" do
    assert_difference "Topic.count", 1 do
      assert_difference "Comment.count", 2 do
        post branch_creative_comments_path(@creative),
             params: { comment_ids: [ @comment1.id, @comment2.id ], topic_id: @topic.id },
             as: :json
      end
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert json["success"]
    assert_equal "Branch:Original", json["topic"]["name"]
    assert_equal @topic.id, json["topic"]["source_topic_id"]

    # Originals unchanged
    assert_equal @topic.id, @comment1.reload.topic_id
    assert_equal @topic.id, @comment2.reload.topic_id
  end

  test "branch from Main (nil topic_id)" do
    main_comment = @creative.comments.create!(content: "Main msg", user: @user, topic_id: nil)

    post branch_creative_comments_path(@creative),
         params: { comment_ids: [ main_comment.id ] },
         as: :json

    assert_response :created
    json = JSON.parse(response.body)
    assert_match(/Branch:All Messages/, json["topic"]["name"])
    assert_nil json["topic"]["source_topic_id"]
  end

  test "branch preserves quoted_comment_id mapping" do
    @comment2.update!(quoted_comment_id: @comment1.id)

    post branch_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id, @comment2.id ], topic_id: @topic.id },
         as: :json

    assert_response :created
    new_topic = Topic.find(JSON.parse(response.body)["topic"]["id"])
    new_comments = new_topic.comments.order(:created_at)
    assert_equal 2, new_comments.size
    # The second copied comment should quote the first copied comment, not the original
    assert_equal new_comments.first.id, new_comments.second.quoted_comment_id
  end

  test "returns error for empty selection" do
    post branch_creative_comments_path(@creative),
         params: { comment_ids: [] },
         as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].present?
  end

  test "returns error for invalid comment ids" do
    post branch_creative_comments_path(@creative),
         params: { comment_ids: [ 99999 ], topic_id: @topic.id },
         as: :json

    assert_response :unprocessable_entity
  end

  test "branch creates unique topic names" do
    # First branch
    post branch_creative_comments_path(@creative),
         params: { comment_ids: [ @comment1.id ], topic_id: @topic.id },
         as: :json
    assert_response :created
    assert_equal "Branch:Original", JSON.parse(response.body)["topic"]["name"]

    # Second branch — name should be unique
    post branch_creative_comments_path(@creative),
         params: { comment_ids: [ @comment2.id ], topic_id: @topic.id },
         as: :json
    assert_response :created
    assert_equal "Branch:Original 2", JSON.parse(response.body)["topic"]["name"]
  end
end
