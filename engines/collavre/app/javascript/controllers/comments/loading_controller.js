import { Controller } from '@hotwired/stimulus'
import { parseEmojis } from '../../utils/emoji_parser'

export default class extends Controller {
  connect() {
    this.popup = this.element.closest('#comments-popup')
    if (this.popup) {
      this.visibilityObserver = new MutationObserver(() => this.syncAnimation())
      this.visibilityObserver.observe(this.popup, { attributes: true, attributeFilter: ['style', 'class', 'hidden'] })
    }
    this.syncAnimation()
  }

  syncAnimation() {
    if (this.popup && (this.popup.hidden || getComputedStyle(this.popup).display === 'none')) {
      this.stopAnimation()
    } else if (!this.animationInterval) {
      this.startAnimation()
    }
  }

  startAnimation() {
    const property = '--creative-loading-emojis'
    const value = getComputedStyle(document.body).getPropertyValue(property).trim() ||
      getComputedStyle(document.documentElement).getPropertyValue(property).trim()
    const emojis = parseEmojis(value.replace(/"/g, ''))
    const dots = this.element.querySelectorAll('.creative-loading-dot')
    let step = 0
    const update = () => {
      const frame = step % 4
      const emoji = emojis[Math.floor(step / 4) % emojis.length]
      dots.forEach((dot, index) => { dot.textContent = frame > 0 && index === 3 - frame ? emoji : '.' })
      step++
    }
    update()
    this.animationInterval = setInterval(update, 120)
  }

  disconnect() {
    this.visibilityObserver?.disconnect()
    this.stopAnimation()
  }

  stopAnimation() {
    clearInterval(this.animationInterval)
    this.animationInterval = null
  }
}
