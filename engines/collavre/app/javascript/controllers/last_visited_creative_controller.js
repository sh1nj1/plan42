import { Controller } from '@hotwired/stimulus'
import { cancelPendingLastVisitedCreative, rememberLastVisitedCreative } from '../lib/last_visited_creative'

// A Turbo restore can replace the entire body, so preserve the visit action
// outside an individual controller instance until the restored page reconnects.
let lastVisitAction = null

export default class extends Controller {
  static values = {
    url: String,
    creativeId: String,
    visitToken: String,
  }

  connect() {
    this.handleVisit = this.handleVisit.bind(this)
    this.handleRender = this.handleRender.bind(this)
    document.addEventListener('turbo:visit', this.handleVisit)
    document.addEventListener('turbo:render', this.handleRender)

    if (lastVisitAction === 'restore') {
      requestAnimationFrame(() => this.rememberRestoredCreative())
    }
  }

  disconnect() {
    document.removeEventListener('turbo:visit', this.handleVisit)
    document.removeEventListener('turbo:render', this.handleRender)
  }

  handleVisit(event) {
    cancelPendingLastVisitedCreative()
    lastVisitAction = event.detail?.action
  }

  handleRender() {
    requestAnimationFrame(() => this.rememberRestoredCreative())
  }

  rememberRestoredCreative() {
    if (lastVisitAction !== 'restore' || !this.element.isConnected) return

    rememberLastVisitedCreative(this.urlValue, this.creativeIdValue, this.visitTokenValue)
    lastVisitAction = null
  }
}
