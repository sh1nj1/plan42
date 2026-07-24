import { Controller } from '@hotwired/stimulus'
import { Turbo } from '@hotwired/turbo-rails'
import { createSubscription } from '../services/cable'

// Keeps the global inbox badge live across WebSocket gaps.
//
// Steady-state, the badge is updated by Turbo Stream broadcasts on the
// `["inbox", user]` stream (see Comment::Broadcastable). Those broadcasts are
// fire-and-forget: ActionCable never replays a message missed while the socket
// was down, so a badge update sent during a Turbo navigation gap, sleep/wake,
// network blip, or server restart was lost until the next full page render
// (the "badge only appears after refresh" bug).
//
// Subscribing to InboxBadgeChannel closes that gap: ActionCable re-runs the
// channel's #subscribed on every (re)connect, and the server transmits the
// authoritative badge snapshot straight back over THIS subscription. We render
// it ourselves (rather than relying on the sibling turbo_stream_from stream,
// which may not have re-attached yet) so the catch-up can't race a reconnect.
export default class extends Controller {
  connect() {
    this.subscription = createSubscription(
      { channel: 'Collavre::InboxBadgeChannel' },
      { received: (snapshot) => Turbo.renderStreamMessage(snapshot) },
    )
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }
}
