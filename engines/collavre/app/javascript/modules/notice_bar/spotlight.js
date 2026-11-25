// Points the user at the element that completes an onboarding mission: a
// pulsing outline on the element plus a fixed-position tip under it. When the
// element lives on another page the key survives the Turbo visit in
// sessionStorage and the spotlight resumes there.

const PENDING_KEY = 'collavre:notice-spotlight'

function isVisible(el) {
  return el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden'
}

export function findTarget(selector) {
  if (!selector) return null
  return Array.from(document.querySelectorAll(selector)).find(isVisible) || null
}

export function rememberPendingSpotlight(key) {
  try { sessionStorage.setItem(PENDING_KEY, key) } catch { /* storage disabled */ }
}

export function takePendingSpotlight() {
  try {
    const key = sessionStorage.getItem(PENDING_KEY)
    sessionStorage.removeItem(PENDING_KEY)
    return key
  } catch {
    return null
  }
}

export class Spotlight {
  constructor() {
    this.reposition = this.reposition.bind(this)
    this.clear = this.clear.bind(this)
  }

  show(el, tipText) {
    this.clear()
    this.el = el
    el.classList.add('notice-spot')
    el.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' })
    if (tipText) {
      this.tip = document.createElement('div')
      this.tip.className = 'notice-spot-tip'
      this.tip.setAttribute('role', 'status')
      this.tip.textContent = tipText
      document.body.appendChild(this.tip)
      this.reposition()
    }
    window.addEventListener('scroll', this.reposition, true)
    window.addEventListener('resize', this.reposition)
    el.addEventListener('click', this.clear, { once: true })
    if (el.matches('textarea, input')) el.focus()
  }

  reposition() {
    if (!this.tip || !this.el) return
    const rect = this.el.getBoundingClientRect()
    const width = this.tip.offsetWidth
    const left = Math.min(Math.max(8, rect.left), window.innerWidth - width - 8)
    // Targets low on screen (the chat composer) keep their controls visible
    // by taking the tip above them.
    const below = rect.bottom + 10
    const above = rect.top > window.innerHeight * 0.6 || below + this.tip.offsetHeight > window.innerHeight
    const top = above ? rect.top - this.tip.offsetHeight - 10 : below
    Object.assign(this.tip.style, { left: `${left}px`, top: `${top}px` })
  }

  clear() {
    this.el?.classList.remove('notice-spot')
    this.el?.removeEventListener('click', this.clear)
    this.tip?.remove()
    this.el = null
    this.tip = null
    window.removeEventListener('scroll', this.reposition, true)
    window.removeEventListener('resize', this.reposition)
  }
}
