// DOM builders for the notice bar. Copy comes from the server as plain text and
// is always assigned through textContent.

export function h(tag, className, text) {
  const el = document.createElement(tag)
  if (className) el.className = className
  if (text != null) el.textContent = text
  return el
}

export function kindClass(item) {
  return `notice-kind-${item.kind}`
}

export function buildStrip(item, { i18n, extra = 0, interactive = true }) {
  const strip = h('div', `notice-strip ${kindClass(item)}`)
  strip.dataset.key = item.key
  strip.append(
    h('span', 'notice-strip__sweep'),
    h('span', 'notice-strip__icon', item.icon),
    h('span', 'notice-strip__tag', item.tag),
    h('span', 'notice-strip__title', item.title),
    h('span', 'notice-strip__summary', item.summary),
    h('span', 'notice-strip__more', i18n.more),
  )
  if (!interactive) return strip

  strip.tabIndex = 0
  strip.setAttribute('role', 'button')
  if (extra > 0) strip.append(h('span', 'notice-strip__count', `+${extra}`))
  const close = h('button', 'notice-strip__close', '×')
  close.type = 'button'
  close.setAttribute('aria-label', i18n.dismiss)
  strip.append(close)
  return strip
}

export function buildPeeks(items) {
  return items.slice(0, 2).map((item, i) => h('div', `notice-peek notice-peek--${i + 1} ${kindClass(item)}`))
}

function buildSteps(steps) {
  const list = h('ul', 'notice-sheet__steps')
  steps.forEach((step, i) => {
    const li = h('li', step.state === 'todo' ? '' : `is-${step.state}`)
    li.append(h('span', 'notice-sheet__step-no', step.state === 'done' ? '✓' : String(i + 1)), document.createTextNode(step.title))
    list.append(li)
  })
  return list
}

function buildButton(text, extraClass) {
  const button = h('button', `notice-sheet__button ${extraClass}`, text)
  button.type = 'button'
  return button
}

// Returns the sheet contents plus the elements the controller wires up.
export function buildSheet(item, i18n) {
  const mission = item.kind === 'mission'
  const ghost = h('div', 'notice-sheet__ghost')
  ghost.append(buildStrip(item, { i18n, interactive: false }))

  const hero = h('div', 'notice-sheet__hero')
  const close = h('button', 'notice-sheet__close', '×')
  close.type = 'button'
  close.setAttribute('aria-label', i18n.close)
  hero.append(h('span', 'notice-sheet__icon', item.icon), h('span', 'notice-sheet__tag', item.tag), close)

  const content = h('div', 'notice-sheet__content')
  const title = h('h2', null, item.title)
  title.id = 'notice-sheet-title'
  content.append(title, h('p', null, item.body))
  if (item.steps) content.append(buildSteps(item.steps))

  const actions = h('div', 'notice-sheet__actions')
  if (mission) actions.append(h('span', 'notice-sheet__hint', i18n.mission_hint))
  const later = buildButton(mission ? i18n.later : i18n.close, 'notice-sheet__later')
  const cta = buildButton(item.cta, 'notice-sheet__button--primary notice-sheet__cta')
  actions.append(later, cta)
  content.append(actions)

  const inner = h('div', 'notice-sheet__inner')
  inner.append(hero, content)
  return { ghost, inner, content, icon: hero.firstChild, close, later, cta }
}

export function buildToast(message, action) {
  const toast = h('div', 'notice-toast')
  toast.append(h('span', null, message))
  if (action) {
    const button = h('button', 'notice-toast__action', action.label)
    button.type = 'button'
    toast.append(button)
  }
  return toast
}

export const CHECK_SVG = '<svg class="notice-strip__check" width="22" height="22" viewBox="0 0 24 24" aria-hidden="true">' +
  '<circle cx="12" cy="12" r="11" fill="rgba(255,255,255,.25)"/>' +
  '<path d="M6.5 12.5l3.8 3.8 7.5-8" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>'
