// Motion helpers for the notice bar. Every animation degrades to a short fade
// under prefers-reduced-motion, and resolves immediately where the Web
// Animations API is missing (jsdom, very old browsers).

export const EASE = {
  out: 'cubic-bezier(.2,.8,.2,1)',
  spring: 'cubic-bezier(.34,1.56,.64,1)',
  morph: 'cubic-bezier(.2,.85,.25,1)',
  back: 'cubic-bezier(.5,0,.2,1)',
  exit: 'cubic-bezier(.4,0,1,1)',
}

const FADE_IN = [{ opacity: 0 }, { opacity: 1 }]
export const HOLD = [{ opacity: 1 }, { opacity: 1 }]
export const FADE_OUT = [{ opacity: 1 }, { opacity: 0 }]

export function prefersReducedMotion() {
  return window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export function animate(el, keyframes, options, reducedKeyframes = FADE_IN) {
  if (!el?.animate) return Promise.resolve()
  const reduce = prefersReducedMotion()
  const opts = { fill: 'none', ...options }
  if (reduce) Object.assign(opts, { duration: Math.min(160, opts.duration ?? 160), delay: 0, easing: 'linear' })
  return el.animate(reduce ? reducedKeyframes : keyframes, opts).finished.catch(() => {})
}

export function cancelAnimations(el) {
  el?.getAnimations?.({ subtree: true }).forEach((animation) => animation.cancel())
}

const CONFETTI_COLORS = ['rgb(245 158 11)', 'rgb(34 197 94)', 'rgb(59 130 246)', 'rgb(236 72 153)', 'rgb(168 85 247)', 'rgb(250 204 21)']

export function confetti(fromEl, count = 46) {
  if (prefersReducedMotion() || !fromEl) return
  const rect = fromEl.getBoundingClientRect()
  for (let i = 0; i < count; i++) {
    const piece = document.createElement('div')
    piece.className = 'notice-confetti'
    piece.style.background = CONFETTI_COLORS[i % CONFETTI_COLORS.length]
    piece.style.left = `${rect.left + rect.width * (0.25 + Math.random() * 0.5)}px`
    piece.style.top = `${rect.top + rect.height / 2}px`
    document.body.appendChild(piece)
    const dx = (Math.random() - 0.5) * 520
    const dy = 120 + Math.random() * 300
    const rot = (Math.random() - 0.5) * 900
    animate(piece, [
      { transform: 'translate(0,0) rotate(0)', opacity: 1 },
      { transform: `translate(${dx * 0.6}px,${-40 - Math.random() * 60}px) rotate(${rot / 2}deg)`, opacity: 1, offset: 0.3 },
      { transform: `translate(${dx}px,${dy}px) rotate(${rot}deg)`, opacity: 0 },
    ], { duration: 1300 + Math.random() * 500, easing: 'cubic-bezier(.2,.6,.4,1)' }).then(() => piece.remove())
  }
}
