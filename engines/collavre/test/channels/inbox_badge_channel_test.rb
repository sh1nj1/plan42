require "test_helper"

class Collavre::InboxBadgeChannelTest < ActionCable::Channel::TestCase
  tests Collavre::InboxBadgeChannel

  test "rejects subscription without a user" do
    stub_connection current_user: nil

    subscribe

    assert subscription.rejected?
  end

  # Pull-on-subscribe: ActionCable re-runs #subscribed on every WebSocket
  # (re)connect, so the server must re-push the authoritative inbox badge count
  # to the user's existing ["inbox", user] Turbo stream. This is what self-heals
  # a count that was missed while the socket was down (Turbo nav gaps,
  # sleep/wake, server restart) — the symptom of "badge only appears on refresh".
  test "subscribing re-broadcasts the current inbox badge count to both targets" do
    user = users(:one)
    inbox = Collavre::Creative.inbox_for(user)
    inbox.comments.create!(
      content: "unread inbox note",
      user: nil,
      skip_default_user: true,
      topic: inbox.system_topic(fallback_user: user)
    )

    stub_connection current_user: user

    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kwargs) {
      broadcasts << { stream: args.first, target: kwargs[:target], locals: kwargs[:locals] }
    }) do
      subscribe
    end

    assert subscription.confirmed?

    inbox_broadcasts = broadcasts.select { |payload| payload[:stream] == [ "inbox", user ] }
    assert inbox_broadcasts.any? { |payload| payload[:target] == "desktop-inbox-badge" && payload.dig(:locals, :count) == 1 },
           "expected desktop inbox badge to be re-broadcast with the unread count on subscribe"
    assert inbox_broadcasts.any? { |payload| payload[:target] == "mobile-inbox-badge" && payload.dig(:locals, :count) == 1 },
           "expected mobile inbox badge to be re-broadcast with the unread count on subscribe"
  end
end
