// Enter on a brand-new creative POSTs it in the background so the next row
// opens at once. Until that POST returns there is no id to position the next
// row after, so the next row carries a deferred anchor instead: a promise of
// the { afterId, beforeId } its own create must send.
const creates = new WeakMap()
const anchors = new WeakMap()

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
// editor on: none at all, or one whose create failed and left it without an id.
export async function cannotEdit(tree) {
  if (!tree) return true
  const create = creates.get(tree)
  if (!create) return false
  await create
  return !tree.dataset.id
}

// Resolves with the anchor for the row after this one: the new id, or on
// failure the slot this row asked for, so the next row still lands there.
export async function postNewCreative(tree, { action, body }, fallback, { save, created, failed }) {
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
    // has already moved on and can't take the draft back.
    tree.dataset.saveState = 'error'
    failed(error)
    return fallback
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
  if (anchor) anchors.delete(tree)
  return anchor
}
