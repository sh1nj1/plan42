import { treeRowElement } from './creative_row_editor_helpers'
import { creativeSaveSnapshotIsEmpty } from './creative_save_state'
import { applySavedProgress } from '../creatives/row_progress'

const revisions = new WeakMap()
const retryAttachmentIds = new WeakMap()
const refreshes = new WeakMap()

// Only the latest queued snapshot may acknowledge or rewrite a row.
// `refreshMissed` refetches the row when an update broadcast was dropped while
// the save was pending: applying it then would have painted over the draft.
export function queuedCreativeCompletion(tree, onComplete, refreshMissed) {
  const previous = revisions.get(tree) || 0
  const revision = previous + 1
  revisions.set(tree, revision)
  tree.dataset.saveState = 'pending'
  const complete = (saved) => {
    if (revisions.get(tree) !== revision) return false
    delete tree.dataset.saveState
    const row = treeRowElement(tree)
    const missedSync = row?.dataset.missedSync === 'true'
    if (row) {
      delete row.dataset.pendingSyncData
      delete row.dataset.missedSync
    }
    onComplete()
    // The row shows the saved text already. Its progress control, and the
    // roll-up of the rows above it, come from the response; nothing else
    // delivers them to the user who saved.
    applySavedProgress(row, saved)
    if (missedSync) refreshMissed(tree)
    // Only a reload held back by the pending save is still owed.
    document.dispatchEvent(new CustomEvent('creative-sync:release'))
    return true
  }
  complete.rollback = () => revisions.set(tree, previous)
  return complete
}

// A row refresh applies its response only if no later refresh was asked for
// and nothing was painted into the row from the editor since.
export function rowRefreshGuard(tree) {
  const token = {}
  refreshes.set(tree, token)
  return () => refreshes.get(tree) === token
}

export function updateQueuedCreativeRow(tree, snapshot) {
  refreshes.delete(tree)
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

// Paint and show the row from the buffer being saved, so closing the editor
// never leaves a blank gap while the request (a POST for a new creative) is in
// flight. A failed save re-hides the row and reopens the editor on the draft.
export function revealCreativeRow(tree, snapshot) {
  const row = tree.querySelector('.creative-row')
  if (!row || creativeSaveSnapshotIsEmpty(snapshot)) return
  updateQueuedCreativeRow(tree, snapshot)
  row.style.display = ''
}

// Swaps the source the server rewrote (e.g. data: URIs moved to blobs) into
// the row cache, unless the row has moved on from the source that was saved.
export function cacheSavedMarkdownSource(tree) {
  return (source, savedSource) => {
    const row = treeRowElement(tree)
    if (row && row.dataset.markdownSource === savedSource) {
      row.dataset.markdownSource = source
      row.requestUpdate?.()
    }
  }
}

export function queuedCreativeStatus(tree) {
  return tree?.dataset.saveState || ''
}

export function hasRetryAttachmentIds(tree) {
  return Boolean(retryAttachmentIds.get(tree)?.length)
}

export function enqueueCreativeSnapshot(queue, request, completion, tree) {
  // The editor drains these IDs before enqueue; retain them until durable acceptance.
  const ids = [...new Set([...(retryAttachmentIds.get(tree) || []), ...(request.deletedAttachmentIds || [])])]
  retryAttachmentIds.set(tree, ids)
  try {
    const id = queue.enqueue({ ...request, deletedAttachmentIds: ids.length ? ids : null })
    retryAttachmentIds.delete(tree)
    return id
  } catch (error) {
    completion.rollback()
    throw error
  }
}
