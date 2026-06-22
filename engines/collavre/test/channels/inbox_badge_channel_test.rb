require "test_helper"

class Collavre::InboxBadgeChannelTest < ActionCable::Channel::TestCase
  tests Collavre::InboxBadgeChannel

  test "rejects subscription without a user" do
    stub_connection current_user: nil

    subscribe

    assert subscription.rejected?
  end

  # Pull-on-subscribe: ActionCable re-runs #subscribed on every WebSocket
  # (re)connect, so the server must re-push the authoritative inbox badge count.
  # The snapshot is delivered through THIS subscription (transmit) rather than
  # re-broadcast to the sibling ["inbox", user] Turbo stream, so it can't race
  # that stream's re-attach on reconnect and get dropped — which would leave the
  # badge stale ("badge only appears on refresh"). transmit only reaches this
  # just-confirmed subscriber, so the snapshot can never be sent to no one.
  test "subscribing transmits the current inbox badge snapshot to its own subscriber" do
    user = users(:one)
    inbox = Collavre::Creative.inbox_for(user)
    inbox.comments.create!(
      content: "unread inbox note",
      user: nil,
      skip_default_user: true,
      topic: inbox.system_topic(fallback_user: user)
    )

    stub_connection current_user: user

    # Must NOT depend on the sibling Turbo stream: nothing should be broadcast.
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*) { flunk "snapshot must be transmitted, not broadcast to a sibling stream" }) do
      subscribe
    end

    assert subscription.confirmed?

    html = transmissions.last
    assert_not_nil html, "expected the channel to transmit a badge snapshot on subscribe"
    assert_includes html, 'action="replace"'
    assert_includes html, 'target="desktop-inbox-badge"'
    assert_includes html, 'target="mobile-inbox-badge"'
    assert_includes html, 'data-count="1"'
  end
end
