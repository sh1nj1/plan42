/**
 * @jest-environment jsdom
 */
import { TypoPopup } from '../typo_popup'

// The popup is shared by the chat composer and the Lexical editor. It is purely
// presentational: it builds the creatable candidate list and reports the chosen
// value through onChoose — it never edits any document itself.

const edit = { currentValue: 'teh', original: 'teh', suggestion: 'the', confidence: 0.4 }

afterEach(() => { document.body.innerHTML = '' })

function flushRaf() {
  const real = window.requestAnimationFrame
  window.requestAnimationFrame = (cb) => { cb(); return 0 }
  return () => { window.requestAnimationFrame = real }
}

test('open pre-fills the input with the current document word (Enter = keep)', () => {
  const popup = new TypoPopup({ labels: {} })
  popup.open(edit, { left: 0, top: 0, bottom: 0, right: 0, width: 0, height: 0 }, { coarsePointer: true })
  expect(popup.popupInput.value).toBe('teh')
  // current word + suggestion both offered
  const labels = [...popup.popupEl.querySelectorAll('.typo-popup-value')].map((el) => el.textContent)
  expect(labels).toEqual(expect.arrayContaining(['teh', 'the']))
})

test('choosing an option reports value + edit through onChoose and closes', () => {
  let chosen = null
  const popup = new TypoPopup({ labels: {}, onChoose: (value, e) => { chosen = { value, e } } })
  popup.open(edit, { left: 0, top: 0 }, { coarsePointer: true })
  popup._choose('the')
  expect(chosen).toEqual({ value: 'the', e: edit })
  expect(popup.isOpen()).toBe(false)
})

test('typing adds the typed word as an always-present custom option', () => {
  const popup = new TypoPopup({ labels: { custom: 'new' } })
  popup.open(edit, { left: 0, top: 0 }, { coarsePointer: true })
  popup.popupInput.value = 'TEH'
  popup.popupInput.dispatchEvent(new Event('input'))
  const labels = [...popup.popupEl.querySelectorAll('.typo-popup-value')].map((el) => el.textContent)
  expect(labels).toContain('TEH')
})

test('option labels render as text, never as markup (DOM-XSS safe)', () => {
  const popup = new TypoPopup({ labels: {} })
  popup.open(edit, { left: 0, top: 0 }, { coarsePointer: true })
  const payload = '<img src=x onerror=alert(1)>'
  popup.popup.setItems([{ value: payload, label: payload, role: 'custom' }])
  const list = popup.popupEl.querySelector('.typo-popup-list')
  expect(list.querySelector('img')).toBeNull()
  expect(list.textContent).toContain(payload)
})

test('a localized aria-label is applied to the input', () => {
  const popup = new TypoPopup({ labels: { inputLabel: '교정' } })
  popup.open(edit, { left: 0, top: 0 }, { coarsePointer: true })
  expect(popup.popupInput.getAttribute('aria-label')).toBe('교정')
})

test('destroy removes the body-mounted popup (no Turbo-cache orphan)', () => {
  const restore = flushRaf()
  try {
    const popup = new TypoPopup({ labels: {} })
    popup.open(edit, { left: 0, top: 0 }, { coarsePointer: false })
    expect(document.body.querySelector('.typo-popup')).not.toBeNull()
    popup.destroy()
    expect(document.body.querySelector('.typo-popup')).toBeNull()
    expect(popup.popupEl).toBeNull()
  } finally {
    restore()
  }
})
