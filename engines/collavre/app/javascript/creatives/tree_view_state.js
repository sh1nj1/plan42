import { getChildrenContainer, setExpanded } from './drag_drop/dom'

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'textarea:not([disabled])',
  'select:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

function scrollContainer(element) {
  return element.closest('main') || document.scrollingElement || document.documentElement
}

function rowId(row) {
  return row.getAttribute('creative-id')
}

function findRow(element, creativeId) {
  return [...element.querySelectorAll('creative-tree-row[creative-id]')]
    .find((row) => rowId(row) === String(creativeId)) || null
}

function focusState(element) {
  const active = document.activeElement
  const row = active?.closest?.('creative-tree-row')
  if (!row || !element.contains(row)) return null

  const controls = [...row.querySelectorAll(FOCUSABLE_SELECTOR)]
  return {
    creativeId: rowId(row),
    controlId: active.id || null,
    controlIndex: controls.indexOf(active),
  }
}

export function captureCreativeTreeViewState(element) {
  const scrolling = scrollContainer(element)
  return {
    scrolling,
    scrollTop: scrolling.scrollTop,
    focus: focusState(element),
    expansion: [...element.querySelectorAll('creative-tree-row[creative-id]')].map((row) => ({
      creativeId: rowId(row),
      expanded: row.hasAttribute('expanded'),
    })),
  }
}

function restoreExpansion(element, expansion) {
  expansion.forEach(({ creativeId, expanded }) => {
    const row = findRow(element, creativeId)
    if (row) setExpanded(row, expanded, getChildrenContainer(row))
  })
}

function restoreFocus(element, focus) {
  if (!focus?.creativeId) return
  const row = findRow(element, focus.creativeId)
  if (!row) return

  const controls = [...row.querySelectorAll(FOCUSABLE_SELECTOR)]
  const byId = focus.controlId ? controls.find((control) => control.id === focus.controlId) : null
  const control = byId || controls[focus.controlIndex]
  control?.focus({ preventScroll: true })
}

export function restoreCreativeTreeViewState(element, state) {
  if (!state) return
  restoreExpansion(element, state.expansion || [])
  state.scrolling.scrollTop = state.scrollTop
  restoreFocus(element, state.focus)
}
