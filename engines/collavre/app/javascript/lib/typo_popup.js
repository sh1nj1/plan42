// Creatable-combobox popup for resolving one typo edit, shared by the chat
// composer (Phase 1) and the Lexical editor (Phase 2). Wraps CommonPopup for
// positioning + list + keyboard navigation and pre-fills the word currently in
// the document so Enter = keep. Typing adds the typed word as an always-present,
// auto-selected custom option (new coinages / proper nouns).
//
// The popup is purely presentational: it never edits the document. The owner
// passes an `onChoose(value, edit)` callback that applies the chosen value in
// whichever surface it controls (textarea value vs. editor.update). This keeps
// the markdown-canonical safety guarantee with the caller — nothing here ever
// serializes anything.

import CommonPopup from './common_popup'
import { buildCandidateList } from './typo_correction'

// Escape by round-tripping through textContent: the browser never reinterprets
// it as markup, the canonical DOM-text sanitizer (recognized as a barrier by
// static XSS analysis) for the user-typed / model-suggested text spliced into
// the popup HTML.
function escapeHtml(value) {
  const el = document.createElement('div')
  el.textContent = String(value)
  return el.innerHTML
}

export class TypoPopup {
  // labels: { keep, custom, inputLabel }; onChoose: (value, edit) => void
  constructor({ labels = {}, onChoose } = {}) {
    this.labels = {
      keep: labels.keep || 'keep',
      custom: labels.custom || 'custom',
      inputLabel: labels.inputLabel || 'correction',
    }
    this.onChoose = onChoose || (() => {})
    this.activeEdit = null
    this.popupEl = null
    this.popupInput = null
    this.popup = null
  }

  _ensure() {
    if (this.popupEl) return
    const el = document.createElement('div')
    el.className = 'typo-popup common-popup'
    el.style.display = 'none'
    el.innerHTML = `
      <input type="text" class="typo-popup-input" />
      <ul class="typo-popup-list" data-popup-list></ul>`
    document.body.appendChild(el)
    this.popupEl = el
    this.popupInput = el.querySelector('.typo-popup-input')
    // Localized assistive label via setAttribute (never parsed as markup).
    this.popupInput.setAttribute('aria-label', this.labels.inputLabel)

    this.popup = new CommonPopup(el, {
      listElement: el.querySelector('.typo-popup-list'),
      renderItem: (item) => {
        const tag = item.role === 'original' ? ` <span class="typo-popup-role">(${escapeHtml(this.labels.keep)})</span>`
          : item.role === 'custom' ? ` <span class="typo-popup-role">(${escapeHtml(this.labels.custom)})</span>` : ''
        return `<span class="typo-popup-value">${escapeHtml(item.label)}</span>${tag}`
      },
      onSelect: (item) => this._choose(item.value),
      onClose: () => { this.activeEdit = null },
    })

    this.popupInput.addEventListener('input', () => this._refreshItems(this.popupInput.value))
    this.popupInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault()
        this._choose(this.popupInput.value)
        return
      }
      if (this.popup.handleKey(event)) {
        const active = this.popup.items[this.popup.activeIndex]
        if (active) this.popupInput.value = active.value
      }
    })
  }

  _refreshItems(typed) {
    const edit = this.activeEdit
    if (!edit) return
    let items = buildCandidateList({
      currentValue: edit.currentValue,
      originalWord: edit.original,
      suggestions: [{ suggestion: edit.suggestion, confidence: edit.confidence }],
    })
    const trimmed = (typed || '').trim()
    if (trimmed && !items.some((i) => i.value === trimmed)) {
      items = [{ value: trimmed, label: trimmed, role: 'custom', isCurrent: false }, ...items]
    }
    this.popup.setItems(items)
    const selectIndex = trimmed
      ? Math.max(0, items.findIndex((i) => i.value === trimmed))
      : Math.max(0, items.findIndex((i) => i.isCurrent))
    this.popup.setActiveIndex(selectIndex)
  }

  _choose(value) {
    const edit = this.activeEdit
    this.popup?.hide()
    if (edit == null || value == null) return
    this.onChoose(String(value), edit)
  }

  // Open the popup for `edit` anchored at a client rect. On a fine pointer we
  // focus + select-all so a keystroke immediately replaces the word; on a coarse
  // pointer (mobile) we don't auto-focus — chip taps are the primary path and an
  // auto-raised keyboard would cover the suggestions.
  open(edit, anchorRect, { coarsePointer = false } = {}) {
    this._ensure()
    this.activeEdit = edit
    this.popupInput.value = edit.currentValue
    this._refreshItems('')
    this.popup.showAt(anchorRect)
    if (!coarsePointer) {
      // showAt keeps the popup hidden until its own rAF; focus()/select() are
      // no-ops while hidden, so defer them one frame later (FIFO).
      requestAnimationFrame(() => {
        this.popupInput.focus()
        this.popupInput.select()
      })
    }
  }

  hide() {
    this.popup?.hide()
  }

  isOpen() {
    return this.popup?.isOpen() ?? false
  }

  destroy() {
    // The popup lives on document.body; drop it so a Turbo page-cache snapshot
    // doesn't serialize an orphan (and CommonPopup's outside-click listeners are
    // detached via hide()).
    this.popup?.hide()
    this.popupEl?.remove()
    this.popupEl = null
    this.popupInput = null
    this.popup = null
    this.activeEdit = null
  }
}
