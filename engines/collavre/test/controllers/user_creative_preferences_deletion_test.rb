require "test_helper"

class UserCreativePreferencesDeletionTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")
    @creative = Collavre::Creative.create!(user: @user, description: "Deletion race")
    @path = "/creatives/#{@creative.id}/user_creative_preferences/update_last_topic"
  end

  test "issuing a fence after the creative disappears returns not found" do
    delete_creative_before_preference_insert do
      post @path, as: :json
    end

    assert_response :not_found
    assert_no_preference
  end

  test "saving All Messages after the creative disappears does not broadcast" do
    stream = "user_#{@user.id}_creative_#{@creative.id}"
    assert_no_broadcasts(Collavre::TopicsChannel.broadcasting_for(stream)) do
      delete_creative_before_preference_insert do
        patch @path, params: { last_topic_id: nil }, as: :json
      end
    end

    assert_response :not_found
    assert_no_preference
  end

  test "expansion save racing with creative deletion returns not found" do
    delete_creative_before_preference_insert do
      post "/creative_expanded_states/toggle",
           params: { creative_id: @creative.id, node_id: @creative.id, expanded: true }, as: :json
    end

    assert_response :not_found
    assert_no_preference
  end

  test "an unrelated foreign key violation still raises" do
    error = ActiveRecord::InvalidForeignKey.new("unrelated foreign key")
    Collavre::UserCreativePreference.stub(:insert_all, ->(*) { raise error }) do
      assert_same error, assert_raises(ActiveRecord::InvalidForeignKey) { post @path, as: :json }
    end
  end

  test "root expansion preferences still work without a creative id" do
    post "/creative_expanded_states/toggle", params: { node_id: @creative.id, expanded: true }, as: :json

    assert_response :success
    preference = Collavre::UserCreativePreference.find_by!(creative_id: nil, user_id: @user.id)
    assert_equal({ @creative.id.to_s => true }, preference.expanded_status)
  end

  private

  def delete_creative_before_preference_insert
    insert = Collavre::UserCreativePreference.method(:insert_all)
    Collavre::UserCreativePreference.stub(:insert_all, lambda { |*args, **options|
      @creative.destroy!
      insert.call(*args, **options)
    }) { yield }
  end

  def assert_no_preference
    assert_not Collavre::UserCreativePreference.exists?(creative_id: @creative.id, user_id: @user.id)
  end
end
