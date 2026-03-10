require "test_helper"

class TopicsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @creative = creatives(:tshirt)
    @user = users(:one)
    @topic = @creative.topics.create!(name: "Existing Topic", user: @user)
    sign_in_as @user, password: "password"
  end

  test "should create topic and broadcast" do
    assert_difference("Topic.count") do
      post collavre.creative_topics_url(@creative), params: { topic: { name: "New Strategy" } }, as: :json
    end

    assert_response :created
  end

  test "should destroy topic and broadcast" do
    assert_difference("Topic.count", -1) do
      delete collavre.creative_topic_url(@creative, @topic)
    end

    assert_response :no_content
  end

  test "should update topic name" do
    patch collavre.creative_topic_url(@creative, @topic), params: { topic: { name: "Updated Name" } }, as: :json

    assert_response :success
    @topic.reload
    assert_equal "Updated Name", @topic.name
  end

  test "should not update topic without permission" do
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    patch collavre.creative_topic_url(@creative, @topic), params: { topic: { name: "Hacked Name" } }, as: :json

    assert_response :forbidden
    @topic.reload
    assert_equal "Existing Topic", @topic.name
  end

  test "should reorder topics" do
    topic2 = @creative.topics.create!(name: "Topic 2", user: @user)
    topic3 = @creative.topics.create!(name: "Topic 3", user: @user)

    # Original order: @topic, topic2, topic3
    assert_equal [ @topic.id, topic2.id, topic3.id ], @creative.topics.reload.pluck(:id)

    # Reorder to: topic3, @topic, topic2
    post reorder_creative_topics_url(@creative), params: { topic_ids: [ topic3.id, @topic.id, topic2.id ] }, as: :json

    assert_response :success
    assert_equal [ topic3.id, @topic.id, topic2.id ], @creative.topics.reload.pluck(:id)
  end

  test "should not reorder topics without permission" do
    topic2 = @creative.topics.create!(name: "Topic 2", user: @user)
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    post reorder_creative_topics_url(@creative), params: { topic_ids: [ topic2.id, @topic.id ] }, as: :json

    assert_response :forbidden
  end

  test "should return error for invalid topic_ids" do
    post reorder_creative_topics_url(@creative), params: { topic_ids: nil }, as: :json

    assert_response :unprocessable_entity
  end

  test "should move topic with comments to another creative" do
    target_creative = creatives(:root_parent)
    comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "test comment")

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    @topic.reload
    comment.reload
    assert_equal target_creative.id, @topic.creative_id
    assert_equal target_creative.id, comment.creative_id, "Comment should move with topic"
  end

  test "should not move topic without permission on source creative" do
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    target_creative = creatives(:root_parent)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :forbidden
  end

  test "should not move topic without write permission on target creative" do
    target_creative = creatives(:root_parent)
    target_creative.update!(user: users(:two))

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :forbidden
  end

  test "should not move topic if duplicate name exists in target" do
    target_creative = creatives(:root_parent)
    target_creative.topics.create!(name: @topic.name, user: @user)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].include?(@topic.name)
  end

  test "new topic should be created at the end after reordering" do
    # Create initial topics
    topic2 = @creative.topics.create!(name: "Topic 2", user: @user)
    topic3 = @creative.topics.create!(name: "Topic 3", user: @user)

    # Verify initial order: @topic(0), topic2(1), topic3(2)
    assert_equal [ @topic.id, topic2.id, topic3.id ], @creative.topics.reload.pluck(:id)

    # Reorder to: topic3(0), @topic(1), topic2(2)
    post reorder_creative_topics_url(@creative), params: { topic_ids: [ topic3.id, @topic.id, topic2.id ] }, as: :json
    assert_response :success

    # Create a new topic - should be at the end (position 3)
    post collavre.creative_topics_url(@creative), params: { topic: { name: "New Topic" } }, as: :json
    assert_response :created

    new_topic = @creative.topics.find_by(name: "New Topic")

    # Verify new topic is at the end
    assert_equal [ topic3.id, @topic.id, topic2.id, new_topic.id ], @creative.topics.reload.pluck(:id)
    assert_equal 3, new_topic.position
  end
end
