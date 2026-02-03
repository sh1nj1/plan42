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
end
