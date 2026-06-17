// Inline typo correction for the chat composer (Phase 1).
//
// Wires the chat textarea to the server endpoint and paints a *volatile*
// highlight overlay: a mirror "backdrop" div sitting exactly behind the textarea
// with <mark> spans over each edit span. The textarea value stays the single
// source of truth — the backdrop is aria-hidden and never serialized, so
// markdown-canonical storage never sees a highlight.
//
// Two highlight states (shape + colour, for colour-blind safety):
//   - auto-applied (confidence >= threshold): faint straight underline
//   - candidate    (below threshold):         wavy dotted underline (needs decision)
//
// Clicking a highlight opens a creatable combobox (reusing CommonPopup for
// positioning + list + keyboard nav) pre-filled with the word currently in the
// document, so Enter = keep. Typing adds the typed word as an always-present,
// auto-selected custom option.

import CommonPopup from '../lib/common_popup'
import csrfFetch from '../lib/api/csrf_fetch'
import {
  detectDevice,
  shouldRun,
  buildCandidateList,
  anchorEdits,
  applyEditAt,
  shiftEditsAfter,
  partitionByThreshold,
} from '../lib/typo_correction'

const DEBOUNCE_MS = 600
const PRINTABLE_KEYDOWN_TTL_MS = 50

let initialized = false

// Mirror the textarea's box metrics onto the backdrop so highlight spans land on
// the exact glyphs. Only the properties that affect text layout are copied.
const MIRRORED_STYLES = [
  'boxSizing', 'width', 'height', 'paddingTop', 'paddingRight', 'paddingBottom',
  'paddingLeft', 'borderTopWidth', 'borderRightWidth', 'borderBottomWidth',
  'borderLeftWidth', 'fontFamily', 'fontSize', 'fontWeight', 'fontStyle',
  'lineHeight', 'letterSpacing', 'textTransform', 'wordSpacing', 'textIndent',
]

// Escape by round-tripping through textContent: the browser never reinterprets
// it as markup, and it's the canonical DOM-text sanitizer (recognized as a
// barrier by static XSS analysis) for the values we splice into the backdrop and
// popup HTML — both of which carry user-typed / model-suggested text.
function escapeHtml(value) {
  const el = document.createElement('div')
  el.textContent = String(value)
  return el.innerHTML
}

export class TypoCorrector {
  constructor(textarea, { settings, location = 'chat', endpoint = '/typo_corrections', getVoiceActive = () => false, labels = {} } = {}) {
    this.textarea = textarea
    this.settings = settings
    this.location = location
    this.endpoint = endpoint
    this.getVoiceActive = getVoiceActive
    this.labels = { keep: labels.keep || 'keep', custom: labels.custom || 'custom' }

    this.edits = [] // anchored edits currently painted: {start,end,original,suggestion,confidence,state}
    this.lastPrintableKeydownAt = null
    this.lastInputAt = null
    this.debounceTimer = null
    this.requestSeq = 0

    this._buildBackdrop()
    this._bind()
  }

  _buildBackdrop() {
    const ta = this.textarea
    const wrap = document.createElement('div')
    wrap.className = 'typo-input-wrap'
    ta.parentNode.insertBefore(wrap, ta)

    this.backdrop = document.createElement('div')
    this.backdrop.className = 'typo-backdrop'
    this.backdrop.setAttribute('aria-hidden', 'true')
    this.highlightLayer = document.createElement('div')
    this.highlightLayer.className = 'typo-highlights'
    this.backdrop.appendChild(this.highlightLayer)

    wrap.appendChild(this.backdrop)
    wrap.appendChild(ta)
    this._syncBackdropStyle()
  }

  _syncBackdropStyle() {
    const computed = getComputedStyle(this.textarea)
    MIRRORED_STYLES.forEach((prop) => {
      this.highlightLayer.style[prop] = computed[prop]
    })
    // The textarea's own border is transparent-mirrored via padding offsets.
    this.highlightLayer.style.borderColor = 'transparent'
    this.highlightLayer.style.borderStyle = 'solid'
  }

  _bind() {
    this._onKeydown = (event) => {
      // A printable keydown immediately preceding the input marks a physical key.
      if (event.key && event.key.length === 1 && !event.ctrlKey && !event.metaKey) {
        this.lastPrintableKeydownAt = performance.now()
      }
    }
    this._onInput = () => {
      // Stamp the input time *now*, while the keydown→input relationship is still
      // fresh. Classifying at detect time (after the debounce) would read a
      // ~600ms gap and misread every physical keypress as a soft keyboard,
      // defeating the default-off physical-keyboard gate.
      this.lastInputAt = performance.now()
      this._syncScroll()
      this._repaint() // keep existing highlights aligned with edited text
      this._scheduleDetect()
    }
    this._onScroll = () => this._syncScroll()

    this.textarea.addEventListener('keydown', this._onKeydown)
    this.textarea.addEventListener('input', this._onInput)
    this.textarea.addEventListener('scroll', this._onScroll)
  }

  destroy() {
    clearTimeout(this.debounceTimer)
    this.textarea.removeEventListener('keydown', this._onKeydown)
    this.textarea.removeEventListener('input', this._onInput)
    this.textarea.removeEventListener('scroll', this._onScroll)
  }

  _syncScroll() {
    this.backdrop.scrollTop = this.textarea.scrollTop
    this.backdrop.scrollLeft = this.textarea.scrollLeft
  }

  _currentDevice() {
    return detectDevice({
      voiceActive: !!this.getVoiceActive(),
      lastPrintableKeydownAt: this.lastPrintableKeydownAt,
      inputAt: this.lastInputAt,
    })
  }

  _scheduleDetect() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this._detect(), DEBOUNCE_MS)
  }

  async _detect() {
    const device = this._currentDevice();
    // Reset the printable-keydown marker so a stale value can't mis-classify the
    // next standalone input (e.g. soft-keyboard insert after a physical keypress).
    if (this.lastPrintableKeydownAt != null && performance.now() - this.lastPrintableKeydownAt > PRINTABLE_KEYDOWN_TTL_MS) {
      this.lastPrintableKeydownAt = null
    }

    if (!shouldRun(this.settings, { device, location: this.location })) return
    const text = this.textarea.value
    if (!text.trim()) { this._clear(); return }

    const seq = ++this.requestSeq
    let payload
    try {
      const res = await csrfFetch(this.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ text, device, location: this.location }),
      })
      if (!res.ok) return
      payload = await res.json()
    } catch {
      return
    }
    if (seq !== this.requestSeq) return // a newer keystroke superseded this one
    // The text may have changed while the request was in flight; only act if the
    // edits still anchor to the *current* textarea value.
    if (this.textarea.value !== text) return

    this._applyResult(payload)
  }

  _applyResult({ edits = [], threshold = 80 } = {}) {
    const original = this.textarea.value
    const anchored = anchorEdits(original, edits)
    const { autoApplied, candidates } = partitionByThreshold(anchored, threshold)

    // Walk all edits left-to-right in one pass, rebuilding the text while
    // tracking a running delta. This assigns each tracked edit an *exact* final
    // span, rather than re-searching the corrected word by value afterwards —
    // that search would bind to an earlier identical word (e.g. correcting the
    // second "teh" in "the teh" lands the highlight on the first "the", so undo
    // would rewrite the wrong word).
    const events = [
      ...autoApplied.map((e) => ({ ...e, kind: 'applied' })),
      ...candidates.map((e) => ({ ...e, kind: 'candidate' })),
    ].sort((a, b) => a.start - b.start)

    const originalCaret = this.textarea.selectionStart
    let out = ''
    let cursor = 0
    let delta = 0
    let caret = originalCaret
    const tracked = []
    for (const e of events) {
      if (e.start < cursor) continue // overlapping span; skip defensively
      out += original.slice(cursor, e.start)
      const finalStart = e.start + delta
      if (e.kind === 'applied') {
        out += e.suggestion
        const d = e.suggestion.length - (e.end - e.start)
        if (e.start < originalCaret) caret += d
        delta += d
        tracked.push({
          original: e.original, suggestion: e.suggestion, confidence: e.confidence,
          state: 'applied', currentValue: e.suggestion,
          start: finalStart, end: finalStart + e.suggestion.length,
        })
      } else {
        out += original.slice(e.start, e.end)
        tracked.push({
          original: e.original, suggestion: e.suggestion, confidence: e.confidence,
          state: 'candidate', currentValue: e.original,
          start: finalStart, end: finalStart + e.original.length,
        })
      }
      cursor = e.end
    }
    out += original.slice(cursor)

    this.edits = tracked
    if (out !== original) {
      this.textarea.value = out
      this.textarea.setSelectionRange(caret, caret)
      this.textarea.dispatchEvent(new Event('input', { bubbles: true }))
    }
    this._repaint()
  }

  _clear() {
    this.edits = []
    this._repaint()
  }

  // Paint the backdrop: plain text with <mark> spans over each edit. Marks carry
  // the state class so CSS renders the two underline styles.
  _repaint() {
    // Drop edits that no longer match the live text (user kept typing).
    const text = this.textarea.value
    this.edits = this.edits.filter((e) => text.slice(e.start, e.end) === e.currentValue)

    if (this.edits.length === 0) {
      this.highlightLayer.textContent = text
      return
    }
    const sorted = [...this.edits].sort((a, b) => a.start - b.start)
    let html = ''
    let cursor = 0
    sorted.forEach((edit, i) => {
      if (edit.start < cursor) return // overlapping; skip
      html += escapeHtml(text.slice(cursor, edit.start))
      const cls = edit.state === 'applied' ? 'typo-mark typo-mark-applied' : 'typo-mark typo-mark-candidate'
      html += `<mark class="${cls}" data-typo-index="${i}">${escapeHtml(text.slice(edit.start, edit.end))}</mark>`
      cursor = edit.end
    })
    html += escapeHtml(text.slice(cursor))
    this.highlightLayer.innerHTML = html
    this._wireMarks(sorted)
    this._syncScroll()
  }

  // <mark> has pointer-events:auto (the rest of the backdrop is none), so clicks
  // land on a highlighted word and open the combobox there.
  _wireMarks(sorted) {
    this.highlightLayer.querySelectorAll('.typo-mark').forEach((mark) => {
      const idx = Number(mark.dataset.typoIndex)
      const edit = sorted[idx]
      if (!edit) return
      mark.addEventListener('mousedown', (event) => {
        event.preventDefault()
        this._openPopup(edit, mark)
      })
    })
  }

  _ensurePopup() {
    if (this.popupEl) return
    const el = document.createElement('div')
    el.className = 'typo-popup common-popup'
    el.style.display = 'none'
    el.innerHTML = `
      <input type="text" class="typo-popup-input" aria-label="correction" />
      <ul class="typo-popup-list" data-popup-list></ul>`
    document.body.appendChild(el)
    this.popupEl = el
    this.popupInput = el.querySelector('.typo-popup-input')

    this.popup = new CommonPopup(el, {
      listElement: el.querySelector('.typo-popup-list'),
      // item.label is user-typed / model-suggested text; escapeHtml round-trips
      // it through textContent so it can never be reinterpreted as markup.
      renderItem: (item) => {
        const tag = item.role === 'original' ? ` <span class="typo-popup-role">(${escapeHtml(this.labels.keep)})</span>`
          : item.role === 'custom' ? ` <span class="typo-popup-role">(${escapeHtml(this.labels.custom)})</span>` : ''
        return `<span class="typo-popup-value">${escapeHtml(item.label)}</span>${tag}`
      },
      onSelect: (item) => this._chooseValue(item.value),
      onClose: () => { this._activeEdit = null },
    })

    // Typing builds a creatable option and keeps input ↔ list bound.
    this.popupInput.addEventListener('input', () => this._refreshPopupItems(this.popupInput.value))
    this.popupInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault()
        this._chooseValue(this.popupInput.value)
        return
      }
      if (this.popup.handleKey(event)) {
        // Sync the input to the active list item (arrow navigation).
        const active = this.popup.items[this.popup.activeIndex]
        if (active) this.popupInput.value = active.value
      }
    })
  }

  _refreshPopupItems(typed) {
    const edit = this._activeEdit
    if (!edit) return
    let items = buildCandidateList({
      currentValue: edit.currentValue,
      originalWord: edit.original,
      suggestions: [{ suggestion: edit.suggestion, confidence: edit.confidence }],
    })
    const trimmed = (typed || '').trim()
    if (trimmed && !items.some((i) => i.value === trimmed)) {
      // Creatable: the typed word is always present and auto-selected.
      items = [{ value: trimmed, label: trimmed, role: 'custom', isCurrent: false }, ...items]
    }
    this.popup.setItems(items)
    // Auto-select the typed custom entry, else the current document value.
    const selectIndex = trimmed
      ? Math.max(0, items.findIndex((i) => i.value === trimmed))
      : Math.max(0, items.findIndex((i) => i.isCurrent))
    this.popup.setActiveIndex(selectIndex)
  }

  _openPopup(edit, anchorEl) {
    this._ensurePopup()
    this._activeEdit = edit
    this.popupInput.value = edit.currentValue
    this._refreshPopupItems('')
    this.popup.showAt(anchorEl.getBoundingClientRect())
    // Desktop: select-all so a keystroke replaces. Mobile keyboard is left to an
    // explicit tap on the input (no auto-focus) — chip taps are the primary path.
    if (!this._isCoarsePointer()) {
      this.popupInput.focus()
      this.popupInput.select()
    }
  }

  _isCoarsePointer() {
    return typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches
  }

  _chooseValue(value) {
    const edit = this._activeEdit
    if (edit == null || value == null) { this.popup?.hide(); return }
    const replacement = String(value)

    if (replacement !== edit.currentValue) {
      const { text, delta } = applyEditAt(this.textarea.value, {
        start: edit.start, end: edit.end, replacement,
      })
      let caret = this.textarea.selectionStart
      if (edit.start < caret) caret += delta
      this.textarea.value = text
      this.textarea.setSelectionRange(caret, caret)
      // Shift later edits, then drop this one (it's now user-confirmed).
      this.edits = shiftEditsAfter(
        this.edits.filter((e) => e !== edit),
        edit.start,
        delta,
      )
      this.textarea.dispatchEvent(new Event('input', { bubbles: true }))
    } else {
      // "Keep" — user resolved it; remove the highlight.
      this.edits = this.edits.filter((e) => e !== edit)
    }

    this.popup?.hide()
    this._repaint()
    this.textarea.focus()
  }
}

// Module-scope init, mirroring mention_menu.js. Reads settings exposed by the
// server on #comments-popup and only attaches when the master switch is on.
function readSettings(root) {
  if (!root) return null
  const d = root.dataset
  if (d.typoEnabled == null) return null
  return {
    enabled: d.typoEnabled === 'true',
    threshold: parseInt(d.typoThreshold, 10) || 80,
    onVoice: d.typoOnVoice === 'true',
    onSoftKeyboard: d.typoOnSoftKeyboard === 'true',
    onPhysicalKeyboard: d.typoOnPhysicalKeyboard === 'true',
    inChat: d.typoInChat === 'true',
    inEditor: d.typoInEditor === 'true',
  }
}

export function initTypoCorrector() {
  const textarea = document.querySelector('#new-comment-form textarea')
  const root = document.getElementById('comments-popup')
  const settings = readSettings(root)
  if (!textarea || !settings || !settings.enabled) return null
  if (textarea.dataset.typoBound === 'true') return null
  textarea.dataset.typoBound = 'true'

  const voiceButton = document.getElementById('voice-comments-btn')
  return new TypoCorrector(textarea, {
    settings,
    location: 'chat',
    getVoiceActive: () => voiceButton?.dataset.voiceState === 'listening',
    labels: { keep: root.dataset.typoKeepLabel, custom: root.dataset.typoCustomLabel },
  })
}

if (!initialized) {
  initialized = true
  document.addEventListener('turbo:load', initTypoCorrector)
}
