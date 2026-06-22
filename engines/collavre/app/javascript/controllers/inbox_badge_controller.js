import { Controller } from '@hotwired/stimulus'
import { createSubscription } from '../services/cable'

// Keeps the global inbox badge live across WebSocket gaps.
//
// The badge itself is updated by Turbo Stream broadcasts on the
// `["inbox", user]` stream (see Comment::Broadcastable). Those broadcasts are
// fire-and-forget: ActionCable never replays a message missed while the socket
// was down, so a badge update sent during a Turbo navigation gap, sleep/wake,
// network blip, or server restart was lost until the next full page render
// (the "badge only appears after refresh" bug).
//
// Subscribing to InboxBadgeChannel closes that gap: ActionCable re-runs the
// channel's #subscribed on every (re)connect, which makes the server re-push
// the authoritative count to the inbox stream above. We don't need to handle
// any received data here — the DOM update flows through the existing
// turbo_stream_from subscription. This controller's only job is to hold the
// channel subscription open so the reconnect callback keeps firing.
export default class extends Controller {
  connect() {
    this.subscription = createSubscription({ channel: 'Collavre::InboxBadgeChannel' })
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }
}
