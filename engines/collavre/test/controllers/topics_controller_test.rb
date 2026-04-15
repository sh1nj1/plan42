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

  test "should include primary_agent in update response" do
    ai_agent = User.create!(
      email: "agent-update@test.local", password: "password123", name: "UpdateAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    @topic.set_primary_agent!(ai_agent)

    patch collavre.creative_topic_url(@creative, @topic), params: { topic: { name: "Renamed" } }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Renamed", json["name"]
    assert json["primary_agent"].present?, "Response must include primary_agent"
    assert_equal ai_agent.id, json["primary_agent"]["id"]
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

  test "should set primary agent on topic" do
    ai_agent = User.create!(
      email: "agent@test.local", password: "password123", name: "TestAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: ai_agent.id }, as: :json

    assert_response :success
    policy = Collavre::OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: @topic.id)
    assert_equal ai_agent.id, policy.config["primary_agent_id"]
  end

  test "should replace existing primary agent" do
    old_agent = User.create!(
      email: "old@test.local", password: "password123", name: "OldAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    new_agent = User.create!(
      email: "new@test.local", password: "password123", name: "NewAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    @topic.set_primary_agent!(old_agent)

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: new_agent.id }, as: :json

    assert_response :success
    policy = Collavre::OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: @topic.id)
    assert_equal new_agent.id, policy.config["primary_agent_id"]
  end

  test "should reject non-AI user as primary agent" do
    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: @user.id }, as: :json

    assert_response :unprocessable_entity
  end

  test "should reject invalid agent_id" do
    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: 999999 }, as: :json

    assert_response :unprocessable_entity
  end

  test "should create topic with agent_id" do
    ai_agent = User.create!(
      email: "agent2@test.local", password: "password123", name: "Agent2",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )

    assert_difference("Topic.count") do
      post collavre.creative_topics_url(@creative),
        params: { topic: { name: "Talk to Agent2" }, agent_id: ai_agent.id }, as: :json
    end

    assert_response :created
    topic = @creative.topics.find_by(name: "Talk to Agent2")
    assert topic.present?
    policy = Collavre::OrchestratorPolicy.find_by(scope_type: "Topic", scope_id: topic.id)
    assert_equal ai_agent.id, policy.config["primary_agent_id"]
  end

  test "should create topic with comment_ids and move comments" do
    comment1 = Collavre::Comment.create!(creative: @creative, user: @user, content: "Message 1")
    comment2 = Collavre::Comment.create!(creative: @creative, user: @user, content: "Message 2")

    assert_difference("Topic.count") do
      post collavre.creative_topics_url(@creative),
        params: { topic: { name: "New Thread" }, comment_ids: [ comment1.id, comment2.id ] }, as: :json
    end

    assert_response :created
    topic = @creative.topics.find_by(name: "New Thread")
    assert topic.present?

    comment1.reload
    comment2.reload
    assert_equal topic.id, comment1.topic_id
    assert_equal topic.id, comment2.topic_id
  end

  test "should return next_name for auto-generated topic name" do
    get next_name_creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["name"].present?
    # First auto-name should be "Topic1" (en locale)
    assert_match(/\A.+1\z/, json["name"])
  end

  test "next_name should increment based on existing topics" do
    @creative.topics.create!(name: "Topic1", user: @user)
    @creative.topics.create!(name: "Topic3", user: @user)

    get next_name_creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    # Should return Topic4 (max existing is 3, so 3+1=4)
    assert_match(/4\z/, json["name"])
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
