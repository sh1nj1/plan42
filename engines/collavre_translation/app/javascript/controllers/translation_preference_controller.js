import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  connect() {
    this.form = this.element.closest('form')
    this.clearCache = () => window.Turbo.cache.clear()
    this.form.addEventListener('turbo:submit-start', this.clearCache)
  }

  disconnect() {
    this.form.removeEventListener('turbo:submit-start', this.clearCache)
  }
}
