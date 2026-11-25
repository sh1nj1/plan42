import creativesApi from '../lib/api/creatives'
import { replaceProgressControl, syncProgressHtmlFromDom } from './tree_renderer'

// Progress the list shows but did not compute: a row's own control after a
// save, and the roll-up of every row above a change. The actor is left out of
// the broadcast that repairs these for everyone else, so the response to its
// own request (or a fetch, where that response is empty) has to.

function rowFor(id) {
  return document.querySelector(`creative-tree-row[creative-id="${id}"]`)
}

function paint(row, entry) {
  if (!row || !entry) return
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

// `data` is a save response: the saved creative's progress, and its ancestors'.
export function applySavedProgress(row, data) {
  paint(row, data)
  const ancestors = Array.isArray(data?.ancestors) ? data.ancestors : []
  ancestors.forEach((ancestor) => paint(rowFor(ancestor.id), ancestor))
}

function rowsAbove(parentId, rows) {
  let row = parentId ? rowFor(parentId) : null
  while (row && !rows.has(row)) {
    rows.add(row)
    const above = row.getAttribute('parent-id')
    row = above ? rowFor(above) : null
  }
}

// A row that changed parents changes the roll-up of both branches, and the
// reorder endpoint answers with no body. Refetches only the rows on screen
// above either parent; a move within one parent changes no roll-up.
export function refreshMovedBranchProgress(fromParentId, toParentId, fetchCreative = creativesApi.get) {
  if (String(fromParentId || '') === String(toParentId || '')) return Promise.resolve()
  const rows = new Set()
  rowsAbove(fromParentId, rows)
  rowsAbove(toParentId, rows)
  return Promise.all(Array.from(rows, (row) => (
    Promise.resolve(row.getAttribute('creative-id'))
      .then(fetchCreative)
      .then((data) => paint(row, data))
      // A stale percentage is repaired by the next sync; nothing to undo here.
      .catch(() => {})
  )))
}
