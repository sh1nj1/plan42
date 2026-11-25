import creativesApi from '../lib/api/creatives'
import { replaceProgressControl, syncProgressHtmlFromDom } from './tree_renderer'
import { listIsFiltered } from './tree_reload_events'

// Progress roll-ups the list shows but did not compute. A drop between parents
// and a new row both change the progress of every row above them, the actor is
// left out of the broadcast that tells everyone else, and neither endpoint
// answers with those values, so the rows on screen are refetched one by one.
//
// None of it applies to a filtered list. The progress shown there is the
// filter's own, which only the list endpoint computes, and the list refetches
// itself after a save or a drop instead (see tree_reload_events.js).

function rowFor(id) {
  return id && document.querySelector(`creative-tree-row[creative-id="${id}"]`)
}

// A linked placement and its origin show the same creative, and an expanded
// placement repeats the rows below its origin.
export function shownElsewhere(row) {
  const id = row?.getAttribute('creative-id')
  if (!id) return false
  const origin = row.dataset.originId || id
  return Array.from(document.querySelectorAll('creative-tree-row')).some((other) => (
    other !== row && [other.getAttribute('creative-id'), other.dataset.originId].includes(origin)
  ))
}

// Whether the row for `id`, or any row above it, is drawn a second time. What
// a move does to such a branch shows in rows the move never touched.
export function branchShownElsewhere(id) {
  for (let row = rowFor(id); row; row = rowFor(row.getAttribute('parent-id'))) {
    if (shownElsewhere(row)) return true
  }
  return false
}

function paint(row, entry) {
  if (!entry) return
  if (entry.progress != null) row.dataset.progressValue = String(entry.progress)
  if (!entry.progress_html) return
  // Keep what the user typed into the row's own controls since it was drawn.
  syncProgressHtmlFromDom(row)
  const html = row.progressHtml
    ? replaceProgressControl(row.progressHtml, entry.progress_html)
    : entry.progress_html
  row.progressHtml = html
  row.dataset.progressHtml = html
}

function rowsAbove(parentId, rows) {
  let row = parentId ? rowFor(parentId) : null
  while (row && !rows.has(row)) {
    rows.add(row)
    const above = row.getAttribute('parent-id')
    row = above ? rowFor(above) : null
  }
}

function refetch(rows, fetchCreative) {
  return Promise.all(Array.from(rows, (row) => (
    Promise.resolve(row.getAttribute('creative-id'))
      .then(fetchCreative)
      .then((data) => paint(row, data))
      // A stale percentage is repaired by the next sync; nothing to undo here.
      .catch(() => {})
  )))
}

// A row that changed parents changes the roll-up of both branches, and the
// reorder endpoint answers with no body. Refetches only the rows on screen
// above either parent; a move within one parent changes no roll-up.
export function refreshMovedBranchProgress(fromParentId, toParentId, fetchCreative = creativesApi.get) {
  if (listIsFiltered() || String(fromParentId || '') === String(toParentId || '')) return Promise.resolve()
  const rows = new Set()
  rowsAbove(fromParentId, rows)
  rowsAbove(toParentId, rows)
  return refetch(rows, fetchCreative)
}

// A row that was just created changes the roll-up of everything above it, and
// the create response names none of it. The editor refetches the parent row
// whole; this covers the rows above that one.
export function refreshProgressAbove(rowId, fetchCreative = creativesApi.get) {
  const row = rowId && !listIsFiltered() ? rowFor(rowId) : null
  const rows = new Set()
  rowsAbove(row?.getAttribute('parent-id'), rows)
  return refetch(rows, fetchCreative)
}
