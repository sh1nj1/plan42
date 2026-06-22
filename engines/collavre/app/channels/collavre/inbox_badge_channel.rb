module Collavre
  # Keeps the global inbox badge in sync without a full page reload.
  #
  # The badge is updated in real time by fire-and-forget Turbo Stream
  # broadcasts on the ["inbox", user] stream (see Comment::Broadcastable).
  # ActionCable does not replay messages missed while a socket is down, so any
  # badge update broadcast during a WebSocket gap (Turbo navigation, sleep/wake,
  # network blip, server restart, the window before the cable connects) was lost
  # until the next full page render — the "badge only shows up after refresh" bug.
  #
  # This channel closes that gap with the established pull-on-subscribe pattern:
  # ActionCable re-runs #subscribed on every (re)connect, so we re-push the
  # authoritative count to the user's existing inbox stream each time. No client
  # polling, no time window — the server self-heals the count on reconnect.
  class InboxBadgeChannel < ApplicationCable::Channel
    def subscribed
      return reject unless current_user

      # No stream_from: the badge DOM is updated through the user's existing
      # ["inbox", user] Turbo stream. This channel only needs #subscribed to run
      # on every (re)connect so it can re-push the authoritative count there.
      inbox = Creative.inbox_for(current_user)
      Comment.broadcast_inbox_badge(inbox, current_user) if inbox
    end
  end
end
