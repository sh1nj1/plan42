/**
 * @jest-environment jsdom
 */
import { TypoCorrector } from '../typo_corrector'

// Exercises the DOM orchestration that the pure-logic tests don't reach:
// auto-applying high-confidence edits into the textarea (caret preserved),
// painting the two highlight states onto the backdrop, and resolving an edit
// through _chooseValue. Network is bypassed by calling _applyResult directly.

const settings = {
  enabled: true,
  threshold: 80,
  onVoice: true,
  onSoftKeyboard: true,
  onPhysicalKeyboard: false,
  inChat: true,
  inEditor: false,
}

function mount(value) {
  document.body.innerHTML = '<form><textarea>' + value + '</textarea></form>'
  const textarea = document.querySelector('textarea')
  textarea.value = value
  const tc = new TypoCorrector(textarea, { settings })
  return { textarea, tc }
}

describe('TypoCorrector DOM orchestration', () => {
  afterEach(() => { document.body.innerHTML = '' })

  test('wraps textarea in a backdrop overlay', () => {
    const { textarea } = mount('hello')
    expect(textarea.parentNode.classList.contains('typo-input-wrap')).toBe(true)
    expect(textarea.parentNode.querySelector('.typo-highlights')).not.toBeNull()
  })

  test('auto-applies a high-confidence edit into the textarea value', () => {
    const { textarea, tc } = mount('잇습니다 그리고')
    tc._applyResult({
      edits: [{ original: '잇습니다', suggestion: '있습니다', confidence: 0.95 }],
      threshold: 80,
    })
    expect(textarea.value).toBe('있습니다 그리고')
    // The applied edit is highlighted with the "applied" (resolved) state.
    const mark = textarea.parentNode.querySelector('.typo-mark-applied')
    expect(mark).not.toBeNull()
    expect(mark.textContent).toBe('있습니다')
  })

  test('low-confidence edit becomes a candidate highlight, text untouched', () => {
    const { textarea, tc } = mount('teh cat')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }],
      threshold: 80,
    })
    expect(textarea.value).toBe('teh cat') // not auto-applied
    const mark = textarea.parentNode.querySelector('.typo-mark-candidate')
    expect(mark).not.toBeNull()
    expect(mark.textContent).toBe('teh')
  })

  test('choosing the suggestion applies it and clears the highlight', () => {
    const { textarea, tc } = mount('teh cat')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }],
      threshold: 80,
    })
    const edit = tc.edits[0]
    tc._ensurePopup()
    tc._activeEdit = edit
    tc._chooseValue('the')
    expect(textarea.value).toBe('the cat')
    expect(textarea.parentNode.querySelector('.typo-mark')).toBeNull()
  })

  test('keeping (current value) just clears the highlight without changing text', () => {
    const { textarea, tc } = mount('teh cat')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }],
      threshold: 80,
    })
    const edit = tc.edits[0]
    tc._ensurePopup()
    tc._activeEdit = edit
    tc._chooseValue('teh') // keep
    expect(textarea.value).toBe('teh cat')
    expect(tc.edits).toHaveLength(0)
  })

  test('typing past a highlighted span drops the stale highlight on repaint', () => {
    const { textarea, tc } = mount('teh cat')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }],
      threshold: 80,
    })
    expect(tc.edits).toHaveLength(1)
    textarea.value = 'text cat' // user edited the span
    tc._repaint()
    expect(tc.edits).toHaveLength(0)
  })

  test('device classification uses the input-time stamp, surviving the debounce (P1)', () => {
    // Before the fix, the device was classified at detect time (after the 600ms
    // debounce), so the keydown→detect gap read ~600ms and every physical
    // keypress was misread as a soft keyboard — bypassing the default-off gate.
    const realNow = performance.now
    let t = 1000
    performance.now = () => t
    try {
      const { textarea, tc } = mount('')
      textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'a' })) // physical keydown @1000
      t = 1002
      textarea.value = 'a'
      textarea.dispatchEvent(new Event('input', { bubbles: true })) // input @1002 → lastInputAt
      t = 1700 // debounce fires ~700ms later, when _detect calls _currentDevice
      expect(tc._currentDevice()).toBe('physical_keyboard')
    } finally {
      performance.now = realNow
    }
  })

  test('auto-applied edit anchors to the corrected span, not an earlier twin (P2)', () => {
    // "the teh" → correct the 2nd word. The highlight/undo must bind the second
    // word (offset 4), not the pre-existing "the" at offset 0.
    const { textarea, tc } = mount('the teh')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.95, offset: 4 }],
      threshold: 80,
    })
    expect(textarea.value).toBe('the the')
    const edit = tc.edits.find((e) => e.state === 'applied')
    expect(edit.start).toBe(4)
    expect(edit.end).toBe(7)
  })

  test('undo of an auto-applied edit rewrites the corrected span, not an earlier twin (P2)', () => {
    const { textarea, tc } = mount('the teh')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.95, offset: 4 }],
      threshold: 80,
    })
    const edit = tc.edits.find((e) => e.state === 'applied')
    tc._ensurePopup()
    tc._activeEdit = edit
    tc._chooseValue('teh') // undo back to the original
    expect(textarea.value).toBe('the teh')
  })
})
