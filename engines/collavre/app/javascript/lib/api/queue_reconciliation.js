// Restored requests have no live editor callback, even when an executing copy
// still holds a callback for a detached frame. Keep a session-scoped
// invalidation until each row instance has fetched an acknowledged server view.
// Turbo may restore another stale DOM instance, so consuming a key is unsafe.
const sessions = new WeakMap()
const reconciledRows = new WeakMap()

function versions(queue) {
  let session = sessions.get(queue)
  if (!session || session.userId !== queue.userId) {
    session = { userId: queue.userId, versions: new Map() }
    sessions.set(queue, session)
  }
  return session.versions
}

export function recordRestoredCompletion(queue, item) {
  if (!item.dedupeKey) return
  const completed = versions(queue)
  const liveItem = queue.queue?.find(queued => queued.id === item.id)
  if (!item.onSuccess || liveItem?.onSuccess !== item.onSuccess || completed.has(item.dedupeKey)) {
    completed.set(item.dedupeKey, {})
  }
}

export function needsCreativeReconciliation(queue, id, row) {
  const version = versions(queue).get(`creative_${id}`)
  return Boolean(version && reconciledRows.get(row) !== version)
}

export async function fetchReconciledCreative(queue, id, row, { fetch, apply = () => true }) {
  const key = `creative_${id}`
  let version, data
  do {
    version = versions(queue).get(key)
    data = await fetch(id)
  } while (version !== versions(queue).get(key))
  if (apply(data) && row && version) reconciledRows.set(row, version)
  return data
}

export function clearQueueReconciliation(queue) {
  sessions.delete(queue)
}
