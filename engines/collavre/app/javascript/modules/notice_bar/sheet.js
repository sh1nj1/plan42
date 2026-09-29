import { animate, cancelAnimations, prefersReducedMotion, EASE, FADE_OUT } from './motion'
import { buildSheet, kindClass } from './view'

// The detail view a strip morphs into: the sheet starts at the strip's exact
// box, grows into a centered dialog (a bottom sheet on narrow screens) while
// the strip's gradient fades into the hero, and shrinks back on close.

const MOBILE_MAX_WIDTH = 640

const px = (rect) => ({ left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` })

function boxOf(el) {
  const { left, top, width, height } = el.getBoundingClientRect()
  return { left, top, width, height }
}

export default class NoticeSheet {
  constructor(i18n) {
    this.i18n = i18n
    this.backdrop = document.createElement('div')
    this.backdrop.className = 'notice-backdrop'
    this.el = document.createElement('div')
    this.el.className = 'notice-sheet'
    this.el.hidden = true
    this.el.setAttribute('role', 'dialog')
    this.el.setAttribute('aria-modal', 'true')
    this.el.setAttribute('aria-labelledby', 'notice-sheet-title')
    document.body.append(this.backdrop, this.el)
  }

  get isOpen() {
    return !this.el.hidden
  }

  destroy() {
    this.backdrop.remove()
    this.el.remove()
  }

  targetBox(height) {
    const vw = window.innerWidth
    const vh = window.innerHeight
    if (vw < MOBILE_MAX_WIDTH) return { box: { left: 0, top: vh - height, width: vw, height }, radius: '18px 18px 0px 0px' }
    const width = Math.min(560, vw - 48)
    return { box: { left: (vw - width) / 2, top: Math.max(24, (vh - height) / 2 - 20), width, height }, radius: '16px' }
  }

  // Lays the sheet out at its final size and returns the parts to wire up.
  mount(item) {
    this.parts = buildSheet(item, this.i18n)
    this.el.className = `notice-sheet ${kindClass(item)}`
    this.el.replaceChildren(this.parts.ghost, this.parts.inner)
    const width = window.innerWidth < MOBILE_MAX_WIDTH ? window.innerWidth : Math.min(560, window.innerWidth - 48)
    Object.assign(this.el.style, { left: '0px', top: '0px', width: `${width}px`, height: 'auto' })
    this.parts.inner.style.width = `${width}px`
    this.el.hidden = false
    const height = Math.min(this.parts.inner.offsetHeight, window.innerHeight - 48)
    const { box, radius } = this.targetBox(height)
    Object.assign(this.el.style, px(box), { borderRadius: radius })
    this.radius = radius
    return this.parts
  }

  async open(item, strip) {
    const from = boxOf(strip)
    const parts = this.mount(item)
    const to = boxOf(this.el)
    strip.style.visibility = 'hidden'
    this.backdrop.classList.add('is-open')
    animate(this.backdrop, [{ opacity: 0 }, { opacity: 1 }], { duration: 360, fill: 'forwards' })
    if (prefersReducedMotion()) {
      parts.ghost.style.opacity = 0
      await animate(this.el, [], { duration: 160 })
    } else {
      animate(parts.ghost, [{ opacity: 1 }, { opacity: 0 }], { duration: 220, delay: 90, fill: 'both' })
      animate(parts.content, [{ opacity: 0, transform: 'translateY(12px)' }, { opacity: 1, transform: 'none' }], { duration: 320, delay: 240, easing: 'ease-out', fill: 'both' })
      animate(parts.icon, [{ transform: 'scale(.3) rotate(-20deg)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 480, delay: 200, easing: EASE.spring, fill: 'both' })
      await animate(this.el, [{ ...px(from), borderRadius: '0px' }, { ...px(to), borderRadius: this.radius }], { duration: 520, easing: EASE.morph })
    }
    parts.cta.focus()
  }

  async close(strip) {
    const current = boxOf(this.el)
    animate(this.backdrop, [{ opacity: 1 }, { opacity: 0 }], { duration: 320, fill: 'forwards' })
    this.backdrop.classList.remove('is-open')
    if (prefersReducedMotion() || !strip?.isConnected) {
      await animate(this.el, FADE_OUT, { duration: 200, fill: 'forwards' }, FADE_OUT)
    } else {
      animate(this.parts.content, FADE_OUT, { duration: 120, fill: 'forwards' })
      animate(this.parts.ghost, [{ opacity: 0 }, { opacity: 1 }], { duration: 200, delay: 120, fill: 'forwards' })
      await animate(this.el, [{ ...px(current), borderRadius: this.radius }, { ...px(boxOf(strip)), borderRadius: '0px' }], { duration: 440, easing: EASE.back, fill: 'forwards' })
    }
    cancelAnimations(this.el)
    this.el.hidden = true
    if (strip) {
      strip.style.visibility = ''
      animate(strip, [{ filter: 'brightness(1.35)' }, { filter: 'none' }], { duration: 450 }, [{ opacity: 1 }, { opacity: 1 }])
      strip.focus?.({ preventScroll: true })
    }
  }
}
