require "test_helper"
require "ostruct"

class UserCreativePreferencesControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

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

  test "clearing a last topic preserves its ordering tombstone" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")

    patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: topic.id },
          as: :json
    preference = Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)

    patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: nil },
          as: :json

    preference.reload
    assert_nil preference.last_topic_id
    assert_equal 2, preference.last_topic_revision

    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: false }

    assert_equal preference.id, Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id).id
  end

  # The broadcast goes to every session of this user, the one that saved
  # included. Echoing the sender's client_id is what lets that session tell its
  # own change coming back from a sibling session's — last_topic_id cannot,
  # because two sessions can pick the same topic at the same moment.
  test "update_last_topic echoes the sender's client_id on the broadcast" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    preference = Collavre::UserCreativePreference.create!(
      creative: @creative, user: @user, expanded_status: { "expanded" => true }, last_topic_revision: 0
    )
    stream = Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")

    assert_broadcast_on(
      stream,
      { action: "last_topic_changed", last_topic_id: topic.id, last_topic_revision: [ preference.id, 1 ], client_id: "save-abc" }
    ) do
      patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
            params: { last_topic_id: topic.id, client_id: "save-abc" },
            as: :json
    end
  end

  test "update_last_topic broadcasts a nil client_id when the save carries none" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    preference = Collavre::UserCreativePreference.create!(
      creative: @creative, user: @user, expanded_status: { "expanded" => true }, last_topic_revision: 0
    )
    stream = Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")

    assert_broadcast_on(
      stream,
      { action: "last_topic_changed", last_topic_id: topic.id, last_topic_revision: [ preference.id, 1 ], client_id: nil }
    ) do
      patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
            params: { last_topic_id: topic.id },
            as: :json
    end
  end

  test "update_last_topic rejects topic from another creative" do
    other_creative = Collavre::Creative.create!(user: @user, description: "Other")
    other_topic = Collavre::Topic.create!(creative: other_creative, user: @user, name: "Foreign Topic")

    patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: other_topic.id },
          as: :json
    assert_response :unprocessable_entity
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
