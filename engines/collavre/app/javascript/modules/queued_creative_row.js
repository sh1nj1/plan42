import { treeRowElement } from './creative_row_editor_helpers'
import { creativeSaveSnapshotIsEmpty } from './creative_save_state'
import { branchShownElsewhere, refreshProgressAbove, shownElsewhere } from '../creatives/row_progress'

const revisions = new WeakMap()
const retryAttachmentIds = new WeakMap()
const refreshes = new WeakMap()
const owedRefetches = new WeakSet()

// Only the latest queued snapshot may acknowledge or rewrite a row.
// `refreshMissed` refetches the row when an update broadcast was dropped while
// the save was pending: applying it then would have painted over the draft.
// `progressChanged` says the save wrote progress. The server rolls that up
// through ancestors, linked placements and, on completion, descendants; the
// saving user gets no broadcast for any of it, so the list is refetched. A
// later snapshot of text alone supersedes that save without undoing its
// write, so the refetch stays owed until the latest snapshot settles.
export function queuedCreativeCompletion(tree, onComplete, refreshMissed, progressChanged = false) {
  const previous = revisions.get(tree) || 0
  const revision = previous + 1
  revisions.set(tree, revision)
  if (progressChanged) owedRefetches.add(tree)
  tree.dataset.saveState = 'pending'
  const complete = (data) => {
    if (revisions.get(tree) !== revision) return false
    delete tree.dataset.saveState
    const row = treeRowElement(tree)
    const missedSync = row?.dataset.missedSync === 'true'
    if (row) {
      delete row.dataset.pendingSyncData
      delete row.dataset.missedSync
    }
    applyRenderedDescription(row, data?.description_embedded_html)
    onComplete()
    if (missedSync) refreshMissed(tree)
    // Saved text is already on this row, so unless the creative is drawn in
    // another row too, all that is owed for it is a reload the save held back.
    const refetch = owedRefetches.delete(tree) || shownElsewhere(row)
    document.dispatchEvent(new CustomEvent(refetch ? 'creative-sync:refetch' : 'creative-sync:release'))
    return true
  }
  complete.rollback = () => revisions.set(tree, previous)
  return complete
}

function applyRenderedDescription(row, html) {
  if (!row || typeof html !== 'string') return
  row.descriptionHtml = html
  row.dataset.descriptionHtml = html
  row.requestUpdate?.()
}

// A background create refreshes its own row and parent. Repeated branches
// and an adopted child still need the list to reconcile the hierarchy.
export function releaseCreatedRow(tree, adoptedChildId) {
  const parentId = tree.dataset.parentId
  const refetch = adoptedChildId || branchShownElsewhere(parentId)
  if (!refetch) refreshProgressAbove(parentId)
  document.dispatchEvent(new CustomEvent(refetch ? 'creative-sync:refetch' : 'creative-sync:release'))
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
