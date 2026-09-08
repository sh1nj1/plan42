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

async function restoreExpansion(element, expansion, isCurrent) {
  for (const { creativeId, expanded } of expansion) {
    if (!isCurrent()) return false
    const row = findRow(element, creativeId)
    if (!row) continue

    const container = getChildrenContainer(row)
    // A hover expansion is never persisted, so the reloaded payload can render
    // that branch collapsed and unloaded. Expanding the empty container alone
    // would leave the row looking open but blank until the user re-toggles it.
    if (expanded) await expandBranchWithChildren(row, container, { isCurrent })
    else setExpanded(row, false, container)
  }
  return isCurrent()
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

export async function restoreCreativeTreeViewState(element, state, { isCurrent = () => true } = {}) {
  if (!state) return
  const restored = await restoreExpansion(element, state.expansion || [], isCurrent)
  if (!restored || !isCurrent()) return
  state.scrolling.scrollTop = state.scrollTop
  restoreFocus(element, state.focus)
}
