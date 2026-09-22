import { treeRowElement } from './creative_row_editor_helpers'

const revisions = new WeakMap()

// Only the latest queued snapshot may acknowledge or rewrite a row.
export function queuedCreativeCompletion(tree, onComplete) {
  const revision = (revisions.get(tree) || 0) + 1
  revisions.set(tree, revision)
  tree.dataset.saveState = 'pending'
  return () => {
    if (revisions.get(tree) !== revision) return false
    delete tree.dataset.saveState
    onComplete()
    document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
    return true
  }
}

export function updateQueuedCreativeRow(tree, snapshot) {
  const row = treeRowElement(tree)
  if (!row) return
  const markdown = snapshot.contentType === 'markdown'
  row.dataset.descriptionHtml = snapshot.content
  row.descriptionHtml = snapshot.content
  row.dataset.descriptionRawHtml = snapshot.content
  if (snapshot.persistProgress) row.dataset.progressValue = String(snapshot.progress)
  row.dataset.contentType = snapshot.contentType
  row.dataset.markdownSource = markdown ? snapshot.markdownSource : ''
  row.dataset.markdownEditor = markdown ? snapshot.markdownEditor : ''
  row.parentId = tree.dataset.parentId || null
  row.requestUpdate?.()
}
