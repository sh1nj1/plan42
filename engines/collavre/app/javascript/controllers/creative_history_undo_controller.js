import { Controller } from '@hotwired/stimulus'
import { invalidateCreativeTree } from '../lib/creative_tree_invalidation'

export default class extends Controller {
  static values = { timeout: { type: Number, default: 30000 } }

  connect() {
    invalidateCreativeTree()
    this.timer = window.setTimeout(() => this.dismiss(), this.timeoutValue)
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  dismiss() {
    this.element.remove()
  }
}
