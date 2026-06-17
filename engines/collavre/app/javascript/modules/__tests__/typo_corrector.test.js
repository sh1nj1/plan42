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

  test('popup renders option labels as text, never as HTML (DOM-XSS safe)', () => {
    const { tc } = mount('teh cat')
    tc._applyResult({ edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }], threshold: 80 })
    tc._ensurePopup()
    tc._activeEdit = tc.edits[0]
    const payload = '<img src=x onerror=alert(1)>'
    tc.popup.setItems([{ value: payload, label: payload, role: 'custom' }])
    const list = tc.popupEl.querySelector('.typo-popup-list')
    expect(list.querySelector('img')).toBeNull() // not parsed as markup
    expect(list.textContent).toContain(payload) // shown verbatim as text
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

  test('auto-apply does not re-trigger detection, so the undo affordance survives (P2)', () => {
    const { textarea, tc } = mount('잇습니다')
    let detectCalls = 0
    tc._scheduleDetect = () => { detectCalls += 1 }
    tc._applyResult({
      edits: [{ original: '잇습니다', suggestion: '있습니다', confidence: 0.95 }],
      threshold: 80,
    })
    // The synthetic `input` event from our own auto-apply must be swallowed: a
    // re-detect would return [] on the now-clean text and wipe the highlight.
    expect(detectCalls).toBe(0)
    expect(textarea.parentNode.querySelector('.typo-mark-applied')).not.toBeNull()

    // A *real* keystroke afterwards still schedules detection.
    textarea.value = '있습니다 어쩌구'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    expect(detectCalls).toBe(1)
  })

  test('clicking a mark opens the popup and the opening mousedown does not close it', () => {
    // Regression: the popup opens on a mousedown. CommonPopup.showAt registered
    // its document-level outside-click mousedown listener synchronously, so the
    // very mousedown that opened the popup kept bubbling to document, hit that
    // listener (target = the mark, outside the popup), and called hide() — the
    // popup opened and instantly closed, so the user never saw it.
    const { textarea, tc } = mount('teh cat')
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }],
      threshold: 80,
    })
    const mark = textarea.parentNode.querySelector('.typo-mark-candidate')
    expect(mark).not.toBeNull()
    mark.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    expect(tc.popup.isOpen()).toBe(true)
    expect(tc.popupEl.style.display).toBe('block')
  })

  test('opening the popup focuses and selects the input (desktop) for instant replace', () => {
    // showAt keeps the popup visibility:hidden until its own rAF, and a hidden
    // element is not focusable — so focus/select are deferred into a rAF that
    // runs after showAt's. Flush rAF synchronously to exercise that path.
    const realRaf = window.requestAnimationFrame
    window.requestAnimationFrame = (cb) => { cb(); return 0 }
    try {
      const { textarea, tc } = mount('teh cat')
      tc._applyResult({
        edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }],
        threshold: 80,
      })
      const mark = textarea.parentNode.querySelector('.typo-mark-candidate')
      mark.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
      expect(document.activeElement).toBe(tc.popupInput)
      expect(tc.popupInput.value).toBe('teh') // current word, pre-filled
    } finally {
      window.requestAnimationFrame = realRaf
    }
  })

  test('popup input carries a localized aria-label', () => {
    document.body.innerHTML = '<form><textarea></textarea></form>'
    const textarea = document.querySelector('textarea')
    const tc = new TypoCorrector(textarea, { settings, labels: { inputLabel: '교정' } })
    tc._ensurePopup()
    expect(tc.popupInput.getAttribute('aria-label')).toBe('교정')
  })

  test('form reset clears stale marks off the now-empty composer', () => {
    // form.reset() empties the textarea without an `input` event, so without the
    // reset listener the previous draft's marks would linger and stay clickable.
    const realRaf = window.requestAnimationFrame
    window.requestAnimationFrame = (cb) => { cb(); return 0 }
    try {
      document.body.innerHTML = '<form><textarea></textarea></form>'
      const form = document.querySelector('form')
      const textarea = document.querySelector('textarea')
      const tc = new TypoCorrector(textarea, { settings })
      textarea.value = 'teh cat'
      tc._applyResult({ edits: [{ original: 'teh', suggestion: 'the', confidence: 0.4 }], threshold: 80 })
      expect(textarea.parentNode.querySelector('.typo-mark')).not.toBeNull()

      form.reset()
      expect(tc.edits).toHaveLength(0)
      expect(textarea.parentNode.querySelector('.typo-mark')).toBeNull()
    } finally {
      window.requestAnimationFrame = realRaf
    }
  })

  test('destroy unwraps the textarea and clears the bind marker (Turbo before-cache)', () => {
    // Turbo caches the DOM but not JS listeners; the snapshot must not keep the
    // injected backdrop or typoBound, or the restored page would duplicate the
    // overlay / skip re-init and leave correction dead until a full reload.
    document.body.innerHTML = '<form><textarea></textarea></form>'
    const form = document.querySelector('form')
    const textarea = document.querySelector('textarea')
    textarea.dataset.typoBound = 'true'
    const tc = new TypoCorrector(textarea, { settings })
    expect(textarea.parentNode.classList.contains('typo-input-wrap')).toBe(true)

    tc.destroy()
    expect(textarea.dataset.typoBound).toBeUndefined()
    expect(textarea.parentNode).toBe(form) // unwrapped back to the form
    expect(form.querySelector('.typo-input-wrap')).toBeNull()
    expect(form.querySelector('.typo-backdrop')).toBeNull()
  })

  test('earlier corrections stay clickable across detection rounds (not just the last)', () => {
    // Each detection round used to replace this.edits wholesale, and the server
    // is stateless — it never re-reports an already-corrected word. So a second
    // round (triggered by typing more) wiped the first correction's undo mark,
    // leaving only the most recent correction clickable. Earlier corrections must
    // keep their mark so the user can still undo them.
    const { textarea, tc } = mount('잇습니다 hello')

    // Round 1: auto-correct 잇습니다 → 있습니다 (high confidence).
    tc._applyResult({
      edits: [{ original: '잇습니다', suggestion: '있습니다', confidence: 0.95 }],
      threshold: 80,
    })
    expect(textarea.value).toBe('있습니다 hello')
    expect(textarea.parentNode.querySelectorAll('.typo-mark')).toHaveLength(1)

    // User types another typo; a fresh detection round returns only the NEW word.
    textarea.value = '있습니다 hello teh'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    tc._applyResult({
      edits: [{ original: 'teh', suggestion: 'the', confidence: 0.95 }],
      threshold: 80,
    })
    expect(textarea.value).toBe('있습니다 hello the')

    // Both corrections must be present and anchored to their own word.
    const marks = [...textarea.parentNode.querySelectorAll('.typo-mark')]
    expect(marks.map((m) => m.textContent).sort()).toEqual(['the', '있습니다'])
    // And each mark resolves to its own edit (not all pointing at the last one).
    const byWord = Object.fromEntries(tc.edits.map((e) => [e.currentValue, e]))
    expect(textarea.value.slice(byWord['있습니다'].start, byWord['있습니다'].end)).toBe('있습니다')
    expect(textarea.value.slice(byWord['the'].start, byWord['the'].end)).toBe('the')
  })
})
