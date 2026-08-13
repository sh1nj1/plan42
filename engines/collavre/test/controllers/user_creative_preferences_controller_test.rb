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

  test "toggle preserves an issued last topic save fence" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    post path, as: :json
    first_fence = response.parsed_body.fetch("last_topic_save_fence")

    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: false }
    assert_response :success

    post path, as: :json
    second_fence = response.parsed_body.fetch("last_topic_save_fence")
    assert_equal first_fence + 1, second_fence

    patch path, params: { last_topic_id: alpha.id, last_topic_save_fence: first_fence }, as: :json
    patch path, params: { last_topic_id: beta.id, last_topic_save_fence: second_fence }, as: :json

    assert_equal true, response.parsed_body["success"]
    preference = Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)
    assert_equal beta.id, preference.last_topic_id
    assert_equal second_fence, preference.last_topic_save_fence_applied
  end

  test "toggle retries when a concurrent collapse removes the preference before locking" do
    preference = Collavre::UserCreativePreference.create!(
      creative_id: @creative.id,
      user_id: @user.id,
      expanded_status: { @creative.id.to_s => true }
    )
    original_find_by = Collavre::UserCreativePreference.method(:find_by!)
    calls = 0

    Collavre::UserCreativePreference.stub(:find_by!, lambda { |**attributes|
      calls += 1
      if calls == 1
        Collavre::UserCreativePreference.where(id: preference.id).delete_all
        preference
      else
        original_find_by.call(**attributes)
      end
    }) do
      post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: false }
    end

    assert_response :success
    assert_equal 2, calls
    assert_nil Collavre::UserCreativePreference.find_by(creative_id: @creative.id, user_id: @user.id)
  end

  test "issuing a save fence retries when collapse removes the preference before locking" do
    preference = empty_preference
    original_find_by = Collavre::UserCreativePreference.method(:find_by!)
    calls = 0

    Collavre::UserCreativePreference.stub(:find_by!, lambda { |**attributes|
      calls += 1
      if calls == 1
        Collavre::UserCreativePreference.where(id: preference.id).delete_all
        preference
      else
        original_find_by.call(**attributes)
      end
    }) do
      post "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic", as: :json
    end

    assert_response :success
    assert_equal 2, calls
    assert_equal 1, response.parsed_body.fetch("last_topic_save_fence")
  end

  test "saving a last topic retries when collapse removes the preference before locking" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    preference = empty_preference
    original_find_by = Collavre::UserCreativePreference.method(:find_by!)
    calls = 0

    Collavre::UserCreativePreference.stub(:find_by!, lambda { |**attributes|
      calls += 1
      if calls == 1
        Collavre::UserCreativePreference.where(id: preference.id).delete_all
        preference
      else
        original_find_by.call(**attributes)
      end
    }) do
      patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
            params: { last_topic_id: topic.id }, as: :json
    end

    assert_response :success
    assert_equal 2, calls
    assert_equal topic.id, Collavre::UserCreativePreference.find_by!(creative: @creative, user: @user).last_topic_id
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
    assert_equal [ record.id, 1 ], response.parsed_body["last_topic_revision"]
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

  test "update_last_topic ignores a late older save from the same client session" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    stream = Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")

    patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
          params: { last_topic_id: beta.id, client_id: "browser-1.2.save-2" },
          as: :json

    assert_response :success
    preference = Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)

    assert_no_broadcasts(stream) do
      patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
            params: { last_topic_id: alpha.id, client_id: "browser-1.1.save-1" },
            as: :json
    end

    assert_response :success
    assert_equal false, response.parsed_body["success"]
    assert_equal true, response.parsed_body["stale_last_topic_save"]
    preference.reload
    assert_equal beta.id, preference.last_topic_id
    assert_equal 1, preference.last_topic_revision
  end

  test "update_last_topic retains each session high-water mark across sibling saves" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    gamma = Collavre::Topic.create!(creative: @creative, user: @user, name: "Gamma")
    stream = Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    patch path, params: { last_topic_id: beta.id, client_id: "browser-a.2.save-2" }, as: :json
    patch path, params: { last_topic_id: gamma.id, client_id: "browser-b.1.save-1" }, as: :json

    assert_no_broadcasts(stream) do
      patch path, params: { last_topic_id: alpha.id, client_id: "browser-a.1.save-1" }, as: :json
    end

    assert_equal false, response.parsed_body["success"]
    preference = Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)
    assert_equal gamma.id, preference.last_topic_id
    assert_equal 2, preference.last_topic_revision
    assert_equal({ "browser-a" => 2, "browser-b" => 1 }, preference.last_topic_save_sequences)
  end

  test "update_last_topic bounds retained session high-water marks" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Topic")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    33.times do |index|
      parameters = { last_topic_id: topic.id, client_id: "browser-#{index}.1.save-1" }
      patch path, params: parameters, as: :json
      assert_response :success
    end

    preference = Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)
    assert_equal 32, preference.last_topic_save_sequences.size
    assert_not preference.last_topic_save_sequences.key?("browser-0")
    assert_equal 1, preference.last_topic_save_sequences.fetch("browser-32")
  end

  test "update_last_topic rejects a delayed fenced save after many later fences" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    path = "/creatives/#{@creative.id}/user_creative_preferences"

    post "#{path}/update_last_topic", as: :json
    first_fence = response.parsed_body.fetch("last_topic_save_fence")

    33.times { post "#{path}/update_last_topic", as: :json }
    latest_fence = response.parsed_body.fetch("last_topic_save_fence")

    patch "#{path}/update_last_topic", params: { last_topic_id: beta.id, last_topic_save_fence: latest_fence }, as: :json

    assert_no_broadcasts(Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")) do
      patch "#{path}/update_last_topic", params: { last_topic_id: alpha.id, last_topic_save_fence: first_fence }, as: :json
    end

    assert_equal false, response.parsed_body["success"]
    preference = Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)
    assert_equal beta.id, preference.last_topic_id
    assert_equal latest_fence, preference.last_topic_save_fence_applied
  end

  test "legacy fallback retires issued fences before a delayed fenced save" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    post path, as: :json
    issued_fence = response.parsed_body.fetch("last_topic_save_fence")

    patch path,
          params: { last_topic_id: beta.id, legacy_last_topic_save_fence_fallback: true },
          as: :json

    assert_no_broadcasts(Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")) do
      patch path, params: { last_topic_id: alpha.id, last_topic_save_fence: issued_fence }, as: :json
    end

    assert_equal false, response.parsed_body["success"]
    preference = Collavre::UserCreativePreference.find_by!(creative: @creative, user: @user)
    assert_equal beta.id, preference.last_topic_id
    assert_equal issued_fence, preference.last_topic_save_fence_applied
  end

  test "legacy save retires issued fences before a delayed fenced save" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    post path, as: :json
    issued_fence = response.parsed_body.fetch("last_topic_save_fence")

    patch path, params: { last_topic_id: beta.id }, as: :json

    assert_no_broadcasts(Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")) do
      patch path, params: { last_topic_id: alpha.id, last_topic_save_fence: issued_fence }, as: :json
    end

    assert_equal false, response.parsed_body["success"]
    preference = Collavre::UserCreativePreference.find_by!(creative: @creative, user: @user)
    assert_equal beta.id, preference.last_topic_id
    assert_equal issued_fence, preference.last_topic_save_fence_applied
  end

  test "fenced save orders a delayed fallback from the same session" do
    alpha = Collavre::Topic.create!(creative: @creative, user: @user, name: "Alpha")
    beta = Collavre::Topic.create!(creative: @creative, user: @user, name: "Beta")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    post path, as: :json
    fence = response.parsed_body.fetch("last_topic_save_fence")

    patch path,
          params: { last_topic_id: beta.id, last_topic_save_fence: fence, client_id: "browser.2.save-2" },
          as: :json

    assert_no_broadcasts(Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")) do
      patch path,
            params: {
              last_topic_id: alpha.id,
              client_id: "browser.1.save-1",
              legacy_last_topic_save_fence_fallback: true
            },
            as: :json
    end

    assert_equal false, response.parsed_body["success"]
    preference = Collavre::UserCreativePreference.find_by!(creative: @creative, user: @user)
    assert_equal beta.id, preference.last_topic_id
    assert_equal({ "browser" => 2 }, preference.last_topic_save_sequences)
  end

  test "update_last_topic rejects a fence that was not issued" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Topic")
    path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"

    post path, as: :json
    issued_fence = response.parsed_body.fetch("last_topic_save_fence")
    stream = Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")

    assert_no_broadcasts(stream) do
      patch path,
            params: { last_topic_id: topic.id, last_topic_save_fence: 9_223_372_036_854_775_807 },
            as: :json
    end

    assert_response :success
    assert_equal false, response.parsed_body["success"]
    assert_equal true, response.parsed_body["stale_last_topic_save"]
    preference = Collavre::UserCreativePreference.find_by!(creative: @creative, user: @user)
    assert_nil preference.last_topic_id
    assert_equal issued_fence, preference.last_topic_save_fence_issued
    assert_equal 0, preference.last_topic_save_fence_applied
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

  private

  def empty_preference
    now = Time.current
    Collavre::UserCreativePreference.insert_all([
      { creative_id: @creative.id, user_id: @user.id, expanded_status: {}, created_at: now, updated_at: now }
    ])
    Collavre::UserCreativePreference.find_by!(creative: @creative, user: @user)
  end
end
