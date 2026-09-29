import { animate, EASE, FADE_OUT } from './motion'
import { buildToast, h } from './view'

// Transient messages (Rails flash, undo prompts). They never join the notice
// stack: one shows at a time under the strip and leaves on its own.

const DURATION = 4000

export default class Toasts {
  constructor(layer) {
    this.layer = layer
  }

  // Server-rendered flash: already in the DOM so it reads without JS.
  adopt(el) {
    this.present(el)
  }

  show(message, action) {
    const toast = buildToast(message, action)
    if (action) {
      toast.querySelector('button').addEventListener('click', () => {
        this.hide(toast)
        action.run()
      })
    }
    this.layer.replaceChildren(toast)
    this.present(toast)
  }

  present(toast) {
    clearTimeout(this.timer)
    const timer = h('span', 'notice-toast__timer')
    toast.append(timer)
    animate(toast, [{ transform: 'translateY(-16px) scale(.9)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 380, easing: EASE.spring })
    timer.animate?.([{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }], { duration: DURATION, fill: 'forwards' })
    this.timer = setTimeout(() => this.hide(toast), DURATION)
  }

  async hide(toast) {
    clearTimeout(this.timer)
    await animate(toast, [{ opacity: 1 }, { transform: 'translateY(-10px)', opacity: 0 }], { duration: 220, fill: 'forwards' }, FADE_OUT)
    toast.remove()
  }

  destroy() {
    clearTimeout(this.timer)
  }
}
