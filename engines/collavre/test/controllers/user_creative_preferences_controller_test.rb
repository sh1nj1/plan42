require "test_helper"
require "ostruct"

class UserCreativePreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "toggle stores expanded state" do
    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: true }
    assert_response :success
    record = Collavre::UserCreativePreference.find_by(creative_id: @creative.id, user_id: @user.id)
    assert_equal({ @creative.id.to_s => true }, record.expanded_status)
  end

  test "toggle removes state when collapsed and no last_topic" do
    Collavre::UserCreativePreference.create!(creative_id: @creative.id, user_id: @user.id, expanded_status: { @creative.id.to_s => true })
    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: false }
    assert_response :success
    assert_nil Collavre::UserCreativePreference.find_by(creative_id: @creative.id, user_id: @user.id)
  end

  test "toggle preserves record when last_topic_id is set" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    Collavre::UserCreativePreference.create!(
      creative_id: @creative.id, user_id: @user.id,
      expanded_status: { @creative.id.to_s => true }, last_topic_id: topic.id
    )
    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: false }
    assert_response :success
    record = Collavre::UserCreativePreference.find_by(creative_id: @creative.id, user_id: @user.id)
    assert_not_nil record
    assert_equal topic.id, record.last_topic_id
  end

  test "update_last_topic saves topic selection" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: topic.id },
          as: :json
    assert_response :success
    record = Collavre::UserCreativePreference.find_by(creative_id: @creative.id, user_id: @user.id)
    assert_equal topic.id, record.last_topic_id
  end

  test "update_last_topic clears topic selection" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    Collavre::UserCreativePreference.create!(
      creative_id: @creative.id, user_id: @user.id,
      expanded_status: { "1" => true }, last_topic_id: topic.id
    )
    patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: nil },
          as: :json
    assert_response :success
    record = Collavre::UserCreativePreference.find_by(creative_id: @creative.id, user_id: @user.id)
    assert_nil record.last_topic_id
  end

  test "update_last_topic requires permission" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    private_creative = Collavre::Creative.create!(user: other_user, description: "Private")
    topic = Collavre::Topic.create!(creative: private_creative, user: other_user, name: "Secret")

    patch "/creatives/#{private_creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: topic.id },
          as: :json
    assert_response :forbidden
  end
end
