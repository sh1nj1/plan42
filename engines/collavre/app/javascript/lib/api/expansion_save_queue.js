import csrfFetch from './csrf_fetch'

// Keep same-user writes ordered across Turbo controller replacements.
let saveQueue = Promise.resolve()
const SAVE_TIMEOUT_MS = 10000

export function queueExpansionSave(userId, state) {
  saveQueue = saveQueue.then(async () => {
    if (!userId || document.body.dataset.currentUserId !== userId) return

    const body = { ...state, expected_user_id: userId }
    // Issuance only reserves an order; a timed-out reservation cannot mutate
    // expansion state. The server counter survives hard reloads and other tabs.
    const { expansion_save_fence: fence } = await saveWithTimeout('fence', body)
    if (!Number.isSafeInteger(fence) || fence <= 0) return
    if (document.body.dataset.currentUserId !== userId) return

    await saveWithTimeout('toggle', { ...body, expansion_save_fence: fence })
  }).catch(() => {})
  return saveQueue
}

async function saveWithTimeout(action, body) {
  const controller = new AbortController()
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort()
      reject(new Error('Expansion save timed out'))
    }, SAVE_TIMEOUT_MS)
  })
  try {
    return await Promise.race([request(action, body, controller.signal), timeout])
  } finally {
    clearTimeout(timer)
  }
}

async function request(action, body, signal) {
  const response = await csrfFetch(`/creative_expanded_states/${action}`, {
    method: 'POST', signal,
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(body),
  })
  if (!response.ok) throw new Error('Expansion save failed')
  // Include response-body stalls in the timeout as well.
  return response.json()
}
