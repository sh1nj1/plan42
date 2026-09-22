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
    return lastIntent
  }
  return (navigator.locks ? navigator.locks.request(key, allocate) : Promise.resolve(allocate())).catch(() => null)
}
