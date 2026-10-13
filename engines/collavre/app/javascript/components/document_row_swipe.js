import { isDocumentView, visitRowLink } from './creative_tree_row_document_view'

const EXCLUDED = 'a, button, input, textarea, select, [contenteditable], img, video, audio, iframe, pre, table, code.lexical-code-block, .mermaid-chart, .lexical-table-wrapper, #inline-edit-form, .popup-menu, .popup-box, dialog, [role="dialog"]'

function selectedText() {
  const selection = window.getSelection?.()
  return selection && !selection.isCollapsed
}

function available(row) {
  const editor = document.getElementById('inline-edit-form')
  return isDocumentView(row) && !row.isTitle && !row.selectMode &&
    !row.closest('[data-select-mode-active]') && !selectedText() &&
    (!editor || editor.style.display === 'none')
}

// Delegation also covers rows loaded later. Passive listeners preserve native
// scrolling; once the initial movement is vertical, this gesture stays rejected.
class DocumentRowSwipe {
  constructor(root) { this.root = root }

  start(event) {
    this.gesture = null
    if (event.touches.length !== 1 || !window.matchMedia('(max-width: 768px)').matches) return
    const row = event.target.closest('creative-tree-row')
    if (!row || !this.root.contains(row) || event.target.closest(EXCLUDED) || !available(row)) return
    const touch = event.touches[0]
    if (touch.clientX > window.innerWidth - 24) return
    this.gesture = { row, id: touch.identifier, x: touch.clientX, y: touch.clientY, time: event.timeStamp, horizontal: false }
  }

  move(event) {
    if (!this.gesture) return
    if (event.touches.length !== 1) return this.cancel()
    const touch = event.touches[0]
    if (touch.identifier !== this.gesture.id) return this.cancel()
    const dx = this.gesture.x - touch.clientX
    const dy = Math.abs(this.gesture.y - touch.clientY)
    if (Math.max(Math.abs(dx), dy) < 12) return
    if (dx <= 0 || dx < dy * 3 || dy > 24) return this.cancel()
    this.gesture.horizontal = true
  }

  end(event) {
    const current = this.gesture
    this.cancel()
    if (!current || event.touches.length || !available(current.row)) return
    const touch = Array.from(event.changedTouches).find(touch => touch.identifier === current.id)
    if (!touch) return
    const dx = current.x - touch.clientX
    const dy = Math.abs(current.y - touch.clientY)
    if (!current.horizontal || dx < 80 || dy > 24 || dx < dy * 3 || event.timeStamp - current.time > 700) return
    visitRowLink(current.row)
  }

  cancel() { this.gesture = null }
}

export function attachDocumentRowSwipe(root) {
  const swipe = new DocumentRowSwipe(root)
  const listeners = Object.fromEntries(['start', 'move', 'end', 'cancel'].map(phase =>
    [`touch${phase}`, swipe[phase].bind(swipe)]))
  Object.entries(listeners).forEach(([type, listener]) => root.addEventListener(type, listener, { passive: true }))
  return () => {
    Object.entries(listeners).forEach(([type, listener]) => root.removeEventListener(type, listener))
    swipe.cancel()
  }
}
