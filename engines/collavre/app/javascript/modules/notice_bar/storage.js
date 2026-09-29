// Defensive wrappers: private browsing or a malformed attribute must never
// break the notice bar.

export function parseJSON(value, fallback) {
  try { return value ? JSON.parse(value) : fallback } catch { return fallback }
}

export function readSession(key) {
  try { return sessionStorage.getItem(key) } catch { return null }
}

export function writeSession(key, value) {
  try { sessionStorage.setItem(key, value) } catch { /* storage disabled */ }
}
