require "test_helper"

class TopicsChannelTest < ActionCable::Channel::TestCase
  tests TopicsChannel

  test "subscribes to creative stream when user has permission" do
    user = users(:one)
    creative = creatives(:tshirt)

    stub_connection current_user: user

    subscribe creative_id: creative.id

    assert subscription.confirmed?
    assert_has_stream_for creative
  end

  test "rejects subscription when missing creative_id" do
    user = users(:one)
    stub_connection current_user: user

    subscribe

    assert subscription.rejected?
  end

  test "rejects subscription when user has no permission" do
    user = users(:two)
    creative = creatives(:tshirt)

    stub_connection current_user: user

    subscribe creative_id: creative.id

    assert subscription.rejected?
  end
end
