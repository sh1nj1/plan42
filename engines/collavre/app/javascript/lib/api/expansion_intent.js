// Request the shared lock at intent time, before any network/queue wait. The
// lock covers only local token allocation, never a request to the server.
let lastIntent = 0
export function reserveExpansionIntent(userId) {
  const timestamp = Math.floor((performance.timeOrigin + performance.now()) * 1000)
  const key = `collavre:expansion-intent:${userId}`
  const allocate = () => {
    let previous = 0
    try { previous = Number(localStorage.getItem(key)) || 0 } catch (_) { /* Storage may be disabled. */ }
    if (!Number.isSafeInteger(previous) || previous < 0) previous = 0
    lastIntent = Math.max(timestamp, lastIntent + 1, previous + 1)
    try { localStorage.setItem(key, String(lastIntent)) } catch (_) { /* Keep the in-document clock. */ }
    return { token: lastIntent, source: expansionSource() }
  }
  return (navigator.locks ? navigator.locks.request('collavre:expansion-intent', allocate) : Promise.resolve(allocate())).catch(() => null)
}

function expansionSource() {
  try {
    const key = 'collavre:expansion-intent-source'
    let source = localStorage.getItem(key)
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(source)) {
      source = crypto.randomUUID()
      localStorage.setItem(key, source)
    }
    return source
  } catch (_) { return null }
}
