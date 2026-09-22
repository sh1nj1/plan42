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
  # authoritative count each time. No client polling, no time window — the server
  # self-heals the count on reconnect.
  class InboxBadgeChannel < ApplicationCable::Channel
    def subscribed
      return reject unless current_user

      # Deliver the snapshot through THIS subscription (transmit), not by
      # re-broadcasting to the sibling ["inbox", user] Turbo stream. On reconnect
      # the two subscriptions re-attach independently, so a broadcast from here
      # could fire before that stream re-attaches and be dropped — leaving the
      # badge stale. transmit only reaches this just-confirmed subscriber, so the
      # snapshot can never be sent while no client is listening.
      inbox = Creative.inbox_for(current_user)
      badge_index = Creatives::CommentBadgeIndex.new(user: current_user)
      badge_index.index([ inbox ])
      snapshot = Comment.inbox_badge_turbo_stream(
        inbox,
        current_user,
        count: badge_index.unread_count_for(inbox)
      )
      transmit(snapshot) if snapshot
    end
  end
end
