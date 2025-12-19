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
      post creative_topics_url(@creative), params: { topic: { name: "New Strategy" } }, as: :json
    end

    assert_response :created
  end

  test "should destroy topic and broadcast" do
    assert_difference("Topic.count", -1) do
      delete creative_topic_url(@creative, @topic)
    end

    assert_response :no_content
  end
end
