// Dependency operations (creation/type changes/archive) need acknowledgment.
export function waitForQueuedRequests(manager, dedupeKey) {
  if (!dedupeKey || !manager.queue.some(item => item.dedupeKey === dedupeKey)) return Promise.resolve()
  return new Promise((resolve, reject) => {
      const cleanup = () => {
          window.removeEventListener('api-queue-request-completed', completed)
          window.removeEventListener('api-queue-request-failed', failed)
      }
      const completed = () => {
          if (manager.queue.some(item => item.dedupeKey === dedupeKey)) return
          cleanup()
          resolve()
      }
      const failed = event => {
          if (event.detail.item.dedupeKey !== dedupeKey) return
          cleanup()
          reject(event.detail.error)
      }
      window.addEventListener('api-queue-request-completed', completed)
      window.addEventListener('api-queue-request-failed', failed)
  })
}

export function mergeQueueCallbacks(existing, incoming) {
    const callbacks = [...existing, incoming].filter(callback => typeof callback === 'function')
    if (!callbacks.length) return null
    return data => callbacks.forEach(callback => {
        try { callback(data) } catch (error) { console.error('Queue callback failed:', error) }
    })
}
