require "test_helper"

class CreativesChannelTest < ActionCable::Channel::TestCase
  tests Collavre::CreativesChannel

  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
  end

  test "subscribes with valid root_id and permission" do
    stub_connection current_user: @user
    subscribe root_id: @creative.id
    assert subscription.confirmed?
  end

  test "rejects without root_id" do
    stub_connection current_user: @user
    subscribe root_id: nil
    assert subscription.rejected?
  end

  test "rejects without current_user" do
    stub_connection current_user: nil
    subscribe root_id: @creative.id
    assert subscription.rejected?
  end

  test "adds user to presence store on subscribe" do
    stub_connection current_user: @user
    subscribe root_id: @creative.id
    assert subscription.confirmed?

    presence_ids = Collavre::CreativePresenceStore.list(@creative.effective_origin.id)
    assert_includes presence_ids, @user.id
  end

  test "removes user from presence store on unsubscribe" do
    stub_connection current_user: @user
    subscribe root_id: @creative.id
    assert subscription.confirmed?

    subscription.unsubscribe_from_channel
    presence_ids = Collavre::CreativePresenceStore.list(@creative.effective_origin.id)
    assert_not_includes presence_ids, @user.id
  end

  test "editing broadcasts editing message" do
    stub_connection current_user: @user
    subscribe root_id: @creative.id

    stream = Collavre::CreativesChannel.broadcasting_for(@creative.effective_origin)
    assert_broadcasts(stream, 1) do
      perform :editing, creative_id: @creative.id
    end
  end

  test "stopped_editing broadcasts stopped_editing message" do
    stub_connection current_user: @user
    subscribe root_id: @creative.id

    stream = Collavre::CreativesChannel.broadcasting_for(@creative.effective_origin)
    assert_broadcasts(stream, 1) do
      perform :stopped_editing, creative_id: @creative.id
    end
  end
end
