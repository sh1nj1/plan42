// Enter on a brand-new creative POSTs it in the background so the next row
// opens at once. Until that POST returns there is no id to position the next
// row after, so the next row carries a deferred anchor instead: a promise of
// the { afterId, beforeId } its own create must send.
const creates = new WeakMap()
const anchors = new WeakMap()
const failedDrafts = new WeakMap()
const dependents = new WeakMap()

export function trackCreate(tree, promise) {
  creates.set(tree, promise)
  promise.finally(() => creates.delete(tree))
  return promise
}

// The row's in-flight background create, if any.
export function pendingCreate(tree) {
  return creates.get(tree)
}

// Waits out a row's background create; true when there is no row to open the
// editor on: none at all, or one left without an id and without a failed draft
// to reopen.
export async function cannotEdit(tree) {
  if (!tree) return true
  const create = creates.get(tree)
  if (!create) return false
  await create
  return !tree.dataset.id && !failedDrafts.has(tree)
}

// Hands over the draft of a row whose background create failed, so the editor
// can reopen it as a new creative and retry the create.
export function takeFailedDraft(tree) {
  const draft = failedDrafts.get(tree)
  failedDrafts.delete(tree)
  return draft
}

// Resolves with the anchor for the row after this one: the new id, or on
// failure the slot this row asked for, so the next row still lands there.
export async function postNewCreative(tree, { action, body, snapshot }, fallback, { save, created, failed }) {
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
    created(data)
    return { afterId: String(data.id), beforeId: '' }
  } catch (error) {
    // The row keeps showing the text; flag it and say so, since the editor
    // has already moved on. Opening the row again restores the draft.
    tree.dataset.saveState = 'error'
    failedDrafts.set(tree, { snapshot, afterId: fallback.afterId, beforeId: fallback.beforeId })
    failed(error)
    return { ...fallback, failedTrees: [...(fallback.failedTrees || []), tree] }
  }
}

// A row that takes over the slot of failed rows above it records them, so
// once it is created they retry in front of it rather than in the old slot,
// which the server would now place after it when that slot is a before_id.
function adoptAnchor(tree, anchor) {
  if (anchor.failedTrees) dependents.set(tree, anchor.failedTrees)
  return anchor
}

export function retargetFailedDrafts(tree, id) {
  for (const failedTree of dependents.get(tree) || []) {
    const draft = failedDrafts.get(failedTree)
    if (draft) Object.assign(draft, { afterId: '', beforeId: String(id) })
  }
  dependents.delete(tree)
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
// the draft it was rejected with.
export function fillFailedDraftForm(form, tree, { snapshot, afterId, beforeId }, inputs) {
  delete tree.dataset.saveState
  form.action = '/creatives'
  form.dataset.creativeId = ''
  const values = {
    methodInput: '',
    parentInput: tree.dataset.parentId || '',
    afterInput: afterId || '',
    beforeInput: beforeId || '',
    childInput: '',
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
