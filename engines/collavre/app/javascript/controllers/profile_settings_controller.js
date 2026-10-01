import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  clearCache() {
    // Restored pages must render reader preferences from the saved user again.
    window.Turbo.cache.clear()
  }
}
