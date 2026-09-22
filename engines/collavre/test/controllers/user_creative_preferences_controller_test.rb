require "test_helper"
require Rails.root.join("test/support/legacy_root_preferences")
require "ostruct"

class UserCreativePreferencesControllerTest < ActionDispatch::IntegrationTest
  include LegacyRootPreferences
  include ActionCable::TestHelper

  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "missing source and legacy intent use fences while malformed sources are rejected" do
    params = { node_id: @creative.id, expanded: true, expansion_intent: 900,
      intent_source: "11111111-1111-4111-8111-111111111111" }
    post "/creative_expanded_states/toggle", params: params.merge(expansion_save_fence: expansion_fence(nil)), as: :json
    assert response.parsed_body["success"]
    fence = expansion_fence(nil)
    [ "invalid", "a" * 1000, [] ].each do |source|
      post "/creative_expanded_states/toggle", params: params.merge(expanded: false, intent_source: source,
        expansion_save_fence: fence), as: :json
      assert response.parsed_body["stale_expansion_save"]
    end
    post "/creative_expanded_states/toggle", params: params.except(:intent_source).merge(expanded: false,
      expansion_intent: 1, expansion_save_fence: fence), as: :json
    assert response.parsed_body["success"]
    assert_nil Collavre::UserCreativePreference.find_by(user: @user, creative_id: nil)
    post "/creative_expanded_states/toggle", params: params.except(:expansion_intent).merge(
      expansion_save_fence: expansion_fence(nil)), as: :json
    assert response.parsed_body["success"]
  end

  test "a slower device can collapse a branch saved by a faster device" do
    [ nil, @creative.id ].each do |context|
      params = { creative_id: context, node_id: @creative.id, expanded: true,
        expansion_intent: 8_000_000_000_000_000, intent_source: "11111111-1111-4111-8111-111111111111" }
      post "/creative_expanded_states/toggle", params: params.merge(expansion_save_fence: expansion_fence(context)), as: :json
      assert response.parsed_body["success"]
      post "/creative_expanded_states/toggle", params: params.merge(expanded: false, expansion_intent: 100,
        intent_source: "22222222-2222-4222-8222-222222222222", expansion_save_fence: expansion_fence(context)), as: :json
      assert response.parsed_body["success"]
      assert_not Collavre::UserCreativePreference.find_by(user: @user, creative_id: context)&.expanded_status&.key?(@creative.id.to_s)
    end
  end

  test "delayed earlier intent with a newer fence cannot resurrect a collapse" do
    [ nil, @creative.id ].each do |context|
      intent = { creative_id: context, node_id: @creative.id, expected_user_id: @user.id }
      post "/creative_expanded_states/toggle", params: intent.merge(expanded: false,
        expansion_save_fence: expansion_fence(context), expansion_intent: 200, intent_source: "11111111-1111-4111-8111-111111111111"), as: :json
      assert_equal true, response.parsed_body["success"]
      post "/creative_expanded_states/toggle", params: intent.merge(expanded: true,
        expansion_save_fence: expansion_fence(context), expansion_intent: 100, intent_source: "11111111-1111-4111-8111-111111111111"), as: :json
      assert_equal true, response.parsed_body["stale_expansion_save"]
      assert_nil Collavre::UserCreativePreference.find_by(user: @user, creative_id: context)
    end
  end

  test "late timed out saves from previous documents cannot overwrite a newer collapse" do
    [ nil, @creative.id ].each do |context|
      intent = { creative_id: context, node_id: @creative.id }
      old_fence = expansion_fence(context)
      new_fence = expansion_fence(context) # A hard reload or a separate tab.
      post "/creative_expanded_states/toggle", params: intent.merge(expanded: false, expansion_save_fence: new_fence), as: :json
      assert_response :success
      assert_equal true, response.parsed_body["success"]
      assert_not Collavre::UserCreativePreference.exists?(user: @user, creative_id: context)

      [ old_fence, new_fence, nil ].each do |fence|
        post "/creative_expanded_states/toggle", params: intent.merge(expanded: true, expansion_save_fence: fence), as: :json
        assert_response :success
        assert_equal true, response.parsed_body["stale_expansion_save"]
        assert_not Collavre::UserCreativePreference.exists?(user: @user, creative_id: context)
      end

      post "/creative_expanded_states/toggle", params: intent.merge(expanded: true, expansion_save_fence: expansion_fence(context)), as: :json
      assert_equal true, response.parsed_body["success"]
      record = Collavre::UserCreativePreference.find_by!(user: @user, creative_id: context)
      assert_equal({ @creative.id.to_s => true }, record.expanded_status)
      post "/creative_expanded_states/toggle", params: intent.merge(expanded: false, expansion_save_fence: old_fence), as: :json
      assert_equal true, response.parsed_body["stale_expansion_save"]
      assert_equal({ @creative.id.to_s => true }, record.reload.expanded_status)
    end
  end

  test "a delayed save for another node still applies across browser documents" do
    first = expansion_fence(nil)
    second = expansion_fence(nil)
    post "/creative_expanded_states/toggle", params: { node_id: @creative.id, expanded: false, expansion_save_fence: second }, as: :json
    post "/creative_expanded_states/toggle", params: { node_id: "another", expanded: true, expansion_save_fence: first }, as: :json
    assert_equal true, response.parsed_body["success"]
    record = Collavre::UserCreativePreference.find_by!(user: @user, creative_id: nil)
    assert_equal({ "another" => true }, record.expanded_status)
  end

  test "invalid or unissued expansion fences are not applied" do
    expansion_fence(nil)
    [ "invalid", 0, -1, 2, "1.5", "9" * 17 ].each do |fence|
      post "/creative_expanded_states/toggle", params: { node_id: @creative.id, expanded: true,
        expansion_save_fence: fence }, as: :json
      assert_response :success
      assert_equal false, response.parsed_body["success"]
    end
  end

  test "fence issuance rejects a previous account without creating a preference" do
    assert_no_difference "Collavre::UserCreativePreference.count" do
      post "/creative_expanded_states/fence", params: { expected_user_id: users(:two).id }, as: :json
      assert_response :forbidden
    end
  end

  test "an unused fence never changes expansion state and subsequent issuance advances" do
    first = expansion_fence(nil)
    assert_not Collavre::UserCreativePreference.exists?(user: @user, creative_id: nil)
    assert_operator expansion_fence(nil), :>, first
    assert_not Collavre::UserCreativePreference.exists?(user: @user, creative_id: nil)
  end

  test "fenced expand and collapse reclaim preferences in every context" do
    [ nil, @creative.id ].each do |context|
      [ true, false ].each do |expanded|
        post "/creative_expanded_states/toggle", params: { creative_id: context, node_id: @creative.id,
          expanded: expanded, expansion_save_fence: expansion_fence(context) }, as: :json
        assert_equal true, response.parsed_body["success"]
        assert_equal expanded, Collavre::UserCreativePreference.exists?(user: @user, creative_id: context)
      end
    end
    assert_equal 2, @user.reload.expansion_save_sequences.fetch("nodes").size
  end

  test "the same node has independent watermarks in different contexts" do
    first = expansion_fence(nil)
    second = expansion_fence(@creative.id)
    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id,
      expanded: false, expansion_save_fence: second }, as: :json
    post "/creative_expanded_states/toggle", params: { node_id: @creative.id,
      expanded: true, expansion_save_fence: first }, as: :json
    assert_equal true, response.parsed_body["success"]
    assert Collavre::UserCreativePreference.exists?(user: @user, creative_id: nil)
    assert_not Collavre::UserCreativePreference.exists?(user: @user, creative_id: @creative.id)
  end

  test "failed preference saves roll back their watermarks" do
    fence = expansion_fence(nil)
    before = @user.reload.expansion_save_sequences
    original_find = Collavre::UserCreativePreference.method(:find_by!)
    Collavre::UserCreativePreference.stub(:find_by!, lambda { |**attributes|
      record = original_find.call(**attributes)
      record.define_singleton_method(:save!) { raise ActiveRecord::RecordInvalid, self }
      record
    }) do
      post "/creative_expanded_states/toggle", params: { node_id: @creative.id,
        expanded: true, expansion_save_fence: fence }, as: :json
      assert_response :unprocessable_entity
    end
    assert_equal before, @user.reload.expansion_save_sequences
    assert_not Collavre::UserCreativePreference.exists?(user: @user, creative_id: nil)
  end

  def expansion_fence(context)
    post "/creative_expanded_states/fence", params: { creative_id: context, expected_user_id: @user.id }, as: :json
    assert_response :success
    response.parsed_body.fetch("expansion_save_fence")
  end

  test "toggle rejects a previous account intent after signing into another account" do
    old_user_id = @user.id
    delete session_path
    other = users(:two)
    other.update!(email_verified_at: Time.current)
    post session_path, params: { email: other.email, password: "password" }

    assert_no_difference "Collavre::UserCreativePreference.count" do
      post "/creative_expanded_states/toggle",
        params: { node_id: @creative.id, expanded: true, expected_user_id: old_user_id }, as: :json
      assert_response :forbidden
    end

    post "/creative_expanded_states/toggle",
      params: { node_id: @creative.id, expanded: true, expected_user_id: other.id }, as: :json
    assert_response :success
    assert Collavre::UserCreativePreference.exists?(user_id: other.id, creative_id: nil)
  end

  test "toggle rejects an explicitly empty expected user" do
    assert_no_difference "Collavre::UserCreativePreference.count" do
      post "/creative_expanded_states/toggle",
        params: { node_id: @creative.id, expanded: true, expected_user_id: "" }, as: :json
      assert_response :forbidden
    end
  end

  test "root toggles reuse one preference and preserve other nodes and contexts" do
    node_ids = [ @creative.id.to_s, "98765" ]
    node_ids.each do |node_id|
      post "/creative_expanded_states/toggle", params: { node_id: node_id, expanded: true }, as: :json
      assert_response :success
    end
    scope = Collavre::UserCreativePreference.where(user_id: @user.id, creative_id: nil)
    assert_equal 1, scope.count
    assert_equal node_ids.index_with { true }, scope.first.expanded_status

    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: true }
    post "/creative_expanded_states/toggle", params: { node_id: node_ids.first, expanded: false }, as: :json
    assert_equal({ node_ids.last => true }, scope.reload.first.expanded_status)
    post "/creative_expanded_states/toggle", params: { node_id: node_ids.last, expanded: false }, as: :json
    assert_empty scope.reload
    assert Collavre::UserCreativePreference.exists?(user_id: @user.id, creative_id: @creative.id)
  end

  test "root saves consolidate legacy duplicates before the unique index is installed" do
    allow_legacy_root_duplicates!
    preference = Collavre::UserCreativePreference
    attributes = { user_id: @user.id, creative_id: nil, expanded_status: { "1" => true } }
    first = preference.create!(attributes)
    preference.insert_all([ attributes.merge(expanded_status: { "legacy" => true }) ],
      unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
    other = preference.create!(attributes.merge(user_id: users(:two).id))

    post "/creative_expanded_states/toggle", params: { node_id: "2", expanded: true }, as: :json
    assert_response :success
    assert_equal [ first.id ], preference.where(user_id: @user.id, creative_id: nil).pluck(:id)
    assert_equal({ "1" => true, "legacy" => true, "2" => true }, first.reload.expanded_status)
    assert_equal({ "1" => true }, other.reload.expanded_status)

    # Reproduce the old composite-targeted writer before index installation.
    assert_difference "Collavre::UserCreativePreference.count", 1 do
      preference.insert_all([ attributes ], unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
    end
  end

  test "root consolidation merges every duplicate before applying the current collapse" do
    allow_legacy_root_duplicates!
    preference = Collavre::UserCreativePreference
    first = preference.create!(user: @user, expanded_status: { "current" => true, "first" => true })
    preference.create!(user: @user, expanded_status: { "current" => true, "second" => true })
    preference.create!(user: @user, expanded_status: { "third" => true })
    context = preference.create!(user: @user, creative: @creative, expanded_status: { "context" => true })

    post "/creative_expanded_states/toggle", params: { node_id: "current", expanded: false,
      expansion_save_fence: expansion_fence(nil) }, as: :json

    assert_response :success
    assert_equal [ first.id ], preference.where(user: @user, creative_id: nil).pluck(:id)
    assert_equal({ "first" => true, "second" => true, "third" => true }, first.reload.expanded_status)
    assert_equal({ "context" => true }, context.reload.expanded_status)
  end

  test "root consolidation leaves later legacy inserts for the next save" do
    allow_legacy_root_duplicates!
    preference = Collavre::UserCreativePreference
    first = preference.create!(user: @user, expanded_status: { "first" => true })
    preference.create!(user: @user, expanded_status: { "legacy" => true })
    inserted = false
    subscriber = lambda do |*, payload|
      if !inserted && payload[:sql].start_with?('UPDATE "user_creative_preferences"')
        inserted = true
        preference.create!(user: @user, expanded_status: { "late" => true })
      end
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      post "/creative_expanded_states/toggle", params: { node_id: "new", expanded: true }, as: :json
      assert_response :success
    end
    assert inserted
    assert_equal 2, preference.where(user: @user, creative_id: nil).count
    assert_equal({ "first" => true, "legacy" => true, "new" => true }, first.reload.expanded_status)

    post "/creative_expanded_states/toggle", params: { node_id: "new", expanded: false }, as: :json
    assert_response :success
    assert_equal [ first.id ], preference.where(user: @user, creative_id: nil).pluck(:id)
    assert_equal({ "first" => true, "legacy" => true, "late" => true }, first.reload.expanded_status)
  end

  test "failed toggles roll back root consolidation and duplicate deletion" do
    allow_legacy_root_duplicates!
    preference = Collavre::UserCreativePreference
    first = preference.create!(user: @user, expanded_status: { "first" => true })
    duplicate = preference.create!(user: @user, expanded_status: { "legacy" => true })
    original_find = preference.method(:find_by!)
    preference.stub(:find_by!, lambda { |**attributes|
      record = original_find.call(**attributes)
      record.define_singleton_method(:save!) { raise ActiveRecord::RecordInvalid, self }
      record
    }) do
      post "/creative_expanded_states/toggle", params: { node_id: "new", expanded: true }, as: :json
      assert_response :unprocessable_entity
    end

    assert_equal({ "first" => true }, first.reload.expanded_status)
    assert_equal({ "legacy" => true }, duplicate.reload.expanded_status)
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
    assert_not record.last_topic_all_messages?
    assert_equal [ record.id, 1 ], response.parsed_body["last_topic_revision"]
    assert_equal false, response.parsed_body["last_topic_all_messages"]
  end

  test "update_last_topic clears topic selection" do
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Test Topic")
    preference = Collavre::UserCreativePreference.create!(
      creative_id: @creative.id, user_id: @user.id,
      expanded_status: { "1" => true }, last_topic_id: topic.id
    )
    stream = Collavre::TopicsChannel.broadcasting_for("user_#{@user.id}_creative_#{@creative.id}")

    assert_broadcast_on(
      stream,
      {
        action: "last_topic_changed", last_topic_id: nil, last_topic_all_messages: true,
        last_topic_revision: [ preference.id, 1 ], client_id: nil
      }
    ) do
      patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
            params: { last_topic_id: nil },
            as: :json
    end

    assert_response :success
    record = preference.reload
    assert_nil record.last_topic_id
    assert record.last_topic_all_messages?
    assert_equal true, response.parsed_body["last_topic_all_messages"]
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
    assert preference.last_topic_all_messages?
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
      {
        action: "last_topic_changed", last_topic_id: topic.id, last_topic_all_messages: false,
        last_topic_revision: [ preference.id, 1 ], client_id: "save-abc"
      }
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
      {
        action: "last_topic_changed", last_topic_id: topic.id, last_topic_all_messages: false,
        last_topic_revision: [ preference.id, 1 ], client_id: nil
      }
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
      patch path, params: { last_topic_id: alpha.id, client_id: "browser.1.save-1" }, as: :json
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

  test "update_last_topic rejects a topic moved before its membership lock" do
    destination = Collavre::Creative.create!(user: @user, description: "Destination")
    topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Moving Topic")
    locked_topics = Collavre::Topic.lock
    moved = false

    Collavre::Topic.stub(:lock, lambda {
      unless moved
        moved = true
        Collavre::Topics::TopicMove.new(topic: topic, target_creative: destination).call
      end
      locked_topics
    }) do
      patch "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic",
            params: { last_topic_id: topic.id },
            as: :json
    end

    assert_response :unprocessable_entity
    assert_equal destination.id, topic.reload.creative_id
    assert_nil Collavre::UserCreativePreference.find_by(creative: @creative, user: @user)
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
