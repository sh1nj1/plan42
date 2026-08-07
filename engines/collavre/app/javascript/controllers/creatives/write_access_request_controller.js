import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../../lib/api/csrf_fetch'

// Powers the "Request write access" CTA in the creative tree's empty state
// (see engines/collavre/app/views/collavre/creatives/_empty_state.html.erb).
//
// There is no backend concept of a "pending request" — Collavre::Concerns::Shareable#request_permission
// just fires a one-off inbox notification to the owner, it doesn't persist request
// state anywhere. So the "pending" pill here is a purely client-side, one-time
// confirmation that the click went through: it swaps in immediately after a
// successful POST and does NOT survive a page reload (a reload has no way to
// know a request is outstanding). That's an intentional, honest scope cut —
// see the PR description for the alternatives considered.
export default class extends Controller {
  static targets = ['button', 'pending']
  static values = { url: String }

  async request(event) {
    event.preventDefault()
    if (!this.hasUrlValue || !this.hasButtonTarget) return

    this.buttonTarget.disabled = true
    try {
      const response = await csrfFetch(this.urlValue, { method: 'POST' })
      if (response.redirected) {
        // fetch() follows redirects by default, so an expired session sends
        // this POST to the sign-in page instead of the permission endpoint —
        // the final response is a 200 for the login form, not a request
        // confirmation. Send the browser to the page it actually landed on
        // rather than claiming the request went through.
        this.redirectToSignIn(response.url)
      } else if (response.ok) {
        this.showPending()
      } else {
        this.buttonTarget.disabled = false
      }
    } catch {
      this.buttonTarget.disabled = false
    }
  }

  showPending() {
    this.buttonTarget.hidden = true
    if (this.hasPendingTarget) {
      this.pendingTarget.hidden = false
    }
  }

  redirectToSignIn(url) {
    window.location.href = url
  }
}
