import { Controller } from '@hotwired/stimulus'
import { parseEmojis } from '../../utils/emoji_parser'

export default class extends Controller {
  connect() {
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
    clearInterval(this.animationInterval)
    this.animationInterval = null
  }
}
