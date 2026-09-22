// Retain executing snapshots and their callbacks; only carry their fields into
// newer requests, with later updates taking precedence over failed snapshots.
export function unacknowledgedBody(queue, dedupeKey) {
  if (!dedupeKey) return {}
  return [...queue.failedItems, ...queue.queue]
    .filter(item => item.dedupeKey === dedupeKey)
    .reduce((body, item) => ({ ...body, ...item.body }), {})
}

export function clearAcknowledgedFailures(queue, item) {
  queue.failedItems = queue.failedItems.filter(failed => !item.dedupeKey || failed.dedupeKey !== item.dedupeKey)
  queue.saveFailedToLocalStorage()
}

// Cleanup belongs to the unacknowledged snapshot, even after editor state resets.
export function unacknowledgedAttachmentIds(queue, dedupeKey) {
  if (!dedupeKey) return []
  return [...queue.failedItems, ...queue.queue]
    .filter(item => item.dedupeKey === dedupeKey)
    .flatMap(item => item.deletedAttachmentIds || [])
}
