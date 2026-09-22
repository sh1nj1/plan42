import { treeRowElement } from './creative_row_editor_helpers'

const revisions = new WeakMap()

// Only the latest queued snapshot may acknowledge or rewrite a row.
export function queuedCreativeCompletion(tree, onComplete) {
  const previous = revisions.get(tree) || 0
  const revision = previous + 1
  revisions.set(tree, revision)
  tree.dataset.saveState = 'pending'
  const complete = () => {
    if (revisions.get(tree) !== revision) return false
    delete tree.dataset.saveState
    const row = treeRowElement(tree)
    if (row) delete row.dataset.pendingSyncData
    onComplete()
    document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
    return true
  }
  complete.rollback = () => revisions.set(tree, previous)
  return complete
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

export function queuedCreativeStatus(tree) {
  return tree?.dataset.saveState || ''
}

export function enqueueCreativeSnapshot(queue, request, completion) {
  try { return queue.enqueue(request) } catch (error) {
    completion.rollback()
    throw error
  }
}
