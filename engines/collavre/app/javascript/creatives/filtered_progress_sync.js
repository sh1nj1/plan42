import { replaceProgressControl, syncProgressHtmlFromDom } from './tree_renderer'
import { refreshFilteredProgress } from '../lib/creative_tree_invalidation'

export function applyProgressControl(row, serverHtml) {
  syncProgressHtmlFromDom(row)
  row.progressHtml = row.progressHtml
    ? replaceProgressControl(row.progressHtml, serverHtml)
    : serverHtml
  row.dataset.progressHtml = row.progressHtml
}

export { refreshFilteredProgress }

export function applyAncestorProgress(ancestors) {
  for (const ancestor of ancestors || []) {
    const row = document.querySelector(`creative-tree-row[creative-id="${ancestor.id}"]`)
    if (!row) continue
    if (ancestor.progress_html) applyProgressControl(row, ancestor.progress_html)
    if (ancestor.progress != null) row.dataset.progressValue = String(ancestor.progress)
  }
}

export function filteredTreeNodes(data) {
  const progress = data?.title_progress
  const row = document.querySelector('creative-tree-row[is-title]')
  if (progress && row?.getAttribute('creative-id') === String(progress.id)) {
    row.dataset.displayProgress = String(progress.display_progress)
    applyProgressControl(row, progress.progress_html)
  }
  return Array.isArray(data?.creatives) ? data.creatives : []
}
