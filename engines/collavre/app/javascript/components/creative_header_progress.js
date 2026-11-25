import { LitElement, html, nothing } from 'lit'
import { styleMap } from 'lit/directives/style-map.js'

class CreativeHeaderProgress extends LitElement {
  static properties = { value: { type: Number }, label: { type: String } }

  createRenderRoot() {
    return this
  }

  render() {
    if (!Number.isFinite(this.value)) return nothing
    const percent = Math.max(0, Math.min(100, this.value * 100))
    const text = `${Math.round(percent)}%`
    return html`
      <span class="creative-header-progress" role="progressbar" tabindex="0"
            aria-label=${this.label} aria-valuenow=${Math.round(percent)}
            data-progress-tooltip=${text}
            style=${styleMap({ '--creative-header-progress': `${percent}%` })}></span>
    `
  }
}

customElements.define('creative-header-progress', CreativeHeaderProgress)
