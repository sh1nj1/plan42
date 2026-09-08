import { getChildrenContainer, setExpanded } from './drag_drop/dom'
import { expandBranchWithChildren } from './branch_expansion'

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
  return row?.getAttribute('creative-id') || null
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
    if (!row) return

    const container = getChildrenContainer(row)
    // A hover expansion is never persisted, so the reloaded payload can render
    // that branch collapsed and unloaded. Expanding the empty container alone
    // would leave the row looking open but blank until the user re-toggles it.
    if (expanded) expandBranchWithChildren(row, container)
    else setExpanded(row, false, container)
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
