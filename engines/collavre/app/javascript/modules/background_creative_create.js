import { applyCreativeSaveResponse } from './creative_save_state'
import { cacheSavedMarkdownSource } from './queued_creative_row'
import { siblingTreeRow, creativeIdFrom } from './creative_tree_dom'
import { treeRowElement } from './creative_row_editor_helpers'

// Enter on a brand-new creative POSTs it in the background so the next row
// opens at once. Until that POST returns there is no id to position the next
// row after, so the next row carries a deferred anchor instead: a promise of
// the { afterId, beforeId } its own create must send.
const creates = new WeakMap()
const anchors = new WeakMap()
const failedDrafts = new WeakMap()
// Rows whose create failed, until one succeeds: reopening a row takes its
// draft out of failedDrafts, but the draft is still unsaved in the editor.
const failedRows = new WeakSet()
const chains = new WeakMap()
const retryDeletes = new WeakMap()
const holds = new WeakMap()
const releases = new WeakMap()
const inFlight = new Set()

export function trackCreate(tree, promise) {
  creates.set(tree, promise)
  inFlight.add(tree)
  promise.finally(() => {
    creates.delete(tree)
    inFlight.delete(tree)
  })
  return promise
}

// A frame swap or page render would take rows still being created out of the
// document, and with them the draft a failed create reopens from. The render
// waits for those creates, including ones started while it waits; if one
// fails it is dropped, so the row stays to retry. A render over a row whose
// create had already failed goes ahead only once the user agrees to discard it.
export function holdRenderForCreates(event, confirmDiscard) {
  const pendingIn = () => [...inFlight].filter((tree) => event.target.contains(tree))
  const failedIn = () => [...event.target.querySelectorAll('.creative-tree')].some((tree) => failedRows.has(tree))
  if (!event.detail?.resume || !(pendingIn().length || failedIn())) return
  event.preventDefault()
  const waited = new Set()
  const settle = () => {
    const pending = pendingIn()
    if (pending.length) {
      pending.forEach((tree) => waited.add(tree))
      Promise.all(pending.map((tree) => creates.get(tree))).then(settle)
    } else if ([...waited].some((tree) => failedRows.has(tree))) {
      return
    } else if (!failedIn()) {
      event.detail.resume()
    } else {
      confirmDiscard().then((discard) => discard && event.detail.resume())
    }
  }
  settle()
}

// The row's in-flight background create, if any, or for a failed row the
// create of the row that took over its slot: its retry slot depends on it.
export function pendingCreate(tree) {
  return creates.get(tree) || holds.get(tree)
}

// Waits out a row's background create; true when there is no row to open the
// editor on: none at all, or one left without an id and without a failed draft
// to reopen.
export async function cannotEdit(tree) {
  if (!tree) return true
  const create = pendingCreate(tree)
  if (!create) return false
  await create
  return !tree.dataset.id && !failedDrafts.has(tree)
}

const saved = (row) => row.isConnected && row.dataset.id

// The id of the first sibling row below this one that has been saved, read
// from the tree as it is now, whatever was added or removed around the row
// since it failed.
function savedIdBelow(tree) {
  let row = siblingTreeRow(treeRowElement(tree), 'next')
  while (row && !creativeIdFrom(row)) row = siblingTreeRow(row, 'next')
  return row ? creativeIdFrom(row) : ''
}

// Hands over the draft of a row whose background create failed, so the editor
// can reopen it as a new creative and retry the create: in front of the first
// saved row below it, else after the nearest saved row of its failed chain
// above it, else in the slot it asked for. The chain outlives the draft, so a
// retry that fails again still knows its neighbours.
export function takeFailedDraft(tree) {
  const draft = failedDrafts.get(tree)
  failedDrafts.delete(tree)
  if (!draft) return draft
  const next = savedIdBelow(tree)
  const previous = chains.get(tree).predecessors.findLast(saved)
  if (next) Object.assign(draft, { afterId: '', beforeId: next })
  else if (previous) Object.assign(draft, { afterId: previous.dataset.id, beforeId: '' })
  return draft
}

// Resolves with the anchor for the row after this one: the new id, or on
// failure the slot this row asked for, so the next row still lands there.
export async function postNewCreative(tree, { action, body, snapshot, deletedIds = [] }, fallback, { save, created, failed }) {
  const anchor = await takeDeferredAnchor(tree)
  if (anchor) {
    Object.assign(fallback, anchor)
    body.set('after_id', anchor.afterId)
    body.set('before_id', anchor.beforeId)
  }
  try {
    const response = await save(action, 'POST', body)
    const data = response.ok ? JSON.parse((await response.text()) || '{}') : {}
    if (!data.id) throw new Error(`Failed to create creative: ${response.status}`)
    delete tree.dataset.saveState
    applyCreativeSaveResponse(snapshot, data, { applyCachedMarkdownSource: cacheSavedMarkdownSource(tree) })
    created(data)
    // A reload deferred while the row was pending has nothing else to release it.
    document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
    return { afterId: String(data.id), beforeId: '' }
  } catch (error) {
    // The row keeps showing the text; flag it and say so, since the editor
    // has already moved on. Opening the row again restores the draft.
    tree.dataset.saveState = 'error'
    failedDrafts.set(tree, { snapshot, afterId: fallback.afterId, beforeId: fallback.beforeId, childId: body.get('child_id') || '' })
    failedRows.add(tree)
    if (!chains.has(tree)) chains.set(tree, { predecessors: fallback.failedTrees || [] })
    retryDeletes.set(tree, [...takeRetryDeletedIds(tree), ...deletedIds])
    failed(error)
    return { ...fallback, failedTrees: [...(fallback.failedTrees || []), tree] }
  } finally {
    releaseFailedRows(tree)
  }
}

// Attachments removed from a draft whose create failed: the editor drained
// them into that request, so they wait here until a create of the row succeeds.
export function takeRetryDeletedIds(tree) {
  const ids = retryDeletes.get(tree) || []
  retryDeletes.delete(tree)
  return ids
}

// A row that takes over the slot of failed rows above it records them: until
// its create settles they hold off reopening, since once it is created they
// must retry in front of it rather than in the old slot, which the server
// would now place after it when that slot is a before_id.
function adoptAnchor(tree, anchor) {
  const failedTrees = anchor.failedTrees
  if (!failedTrees) return anchor
  const settled = new Promise((resolve) => releases.set(tree, () => {
    failedTrees.forEach((failedTree) => holds.get(failedTree) === settled && holds.delete(failedTree))
    resolve()
  }))
  failedTrees.forEach((failedTree) => holds.set(failedTree, settled))
  return anchor
}

// Called once a row's create settles, after a success has retargeted the
// failed rows above it.
export function releaseFailedRows(tree) {
  releases.get(tree)?.()
  releases.delete(tree)
}

// A created row drops its failed chain and its failure; failed rows around it
// find it in the tree when they retry.
export function forgetFailedChain(tree) {
  chains.delete(tree)
  failedRows.delete(tree)
}

// Each edit request takes a ticket. waitToEdit() is falsy when nothing is in
// flight on the row; otherwise it resolves true when the request must be
// dropped: no row, a row left uneditable, or a later request that took over
// the editor while this one waited.
export function createEditTickets() {
  let latest = 0
  return {
    take: () => ++latest,
    waitToEdit(tree) {
      const ticket = ++latest
      if (!tree) return true
      return pendingCreate(tree) && cannotEdit(tree).then((blocked) => blocked || ticket !== latest)
    },
  }
}

// A row opened after a pending create waits for its anchor; any other row
// takes its after_id as is.
export function deferRowAnchor(tree, afterId, afterInput) {
  if (typeof afterId?.then === 'function') {
    anchors.set(tree, afterId)
    afterInput.value = ''
    return
  }
  anchors.delete(tree)
  afterInput.value = afterId || ''
}

// A row moved to another parent or slot before its first save is placed by
// its new siblings; the row it was opened after no longer applies.
export function dropDeferredAnchor(tree) {
  anchors.delete(tree)
}

// Hands the deferred anchor to the first save that needs it.
export function takeDeferredAnchor(tree) {
  const anchor = tree ? anchors.get(tree) : undefined
  if (!anchor) return undefined
  anchors.delete(tree)
  return anchor.then((resolved) => adoptAnchor(tree, resolved))
}

// Markdown authored in the source textarea reopens there; anything else
// reopens in the rich editor.
export function isMarkdownSourceDraft(snapshot) {
  return snapshot.contentType === 'markdown' && snapshot.markdownEditor !== 'rich'
}

// Points the shared form at a new creative in the failed row's slot, holding
// the draft it was rejected with and the child it was to adopt as parent.
export function fillFailedDraftForm(form, tree, { snapshot, afterId, beforeId, childId }, inputs) {
  delete tree.dataset.saveState
  form.action = '/creatives'
  form.dataset.creativeId = ''
  const values = {
    methodInput: '',
    parentInput: tree.dataset.parentId || '',
    afterInput: afterId || '',
    beforeInput: beforeId || '',
    childInput: childId || '',
    originIdInput: snapshot.originId,
    descriptionInput: snapshot.content,
    contentTypeInput: snapshot.contentType,
    markdownSourceInput: snapshot.markdownSource,
    markdownEditorInput: snapshot.markdownEditor,
  }
  for (const [name, value] of Object.entries(values)) {
    if (inputs[name]) inputs[name].value = value
  }
}
