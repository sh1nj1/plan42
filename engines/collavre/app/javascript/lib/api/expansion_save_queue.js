import csrfFetch from './csrf_fetch'

// Keep same-user writes ordered across Turbo controller replacements.
let saveQueue = Promise.resolve()
const SAVE_TIMEOUT_MS = 10000
// getRandomValues also works on HTTP previews, unlike randomUUID.
const saveSession = Array.from(crypto.getRandomValues(new Uint8Array(18)),
  (value) => value.toString(16).padStart(2, '0')).join('')
let saveSequence = 0

export function queueExpansionSave(userId, state) {
  const order = { expansion_save_session: saveSession, expansion_save_sequence: ++saveSequence }
  saveQueue = saveQueue.then(() => {
    if (!userId || document.body.dataset.currentUserId !== userId) return

    return saveWithTimeout({
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      // The cookie can change before Turbo renders the new user's body.
      body: JSON.stringify({ ...state, ...order, expected_user_id: userId }),
    })
  }).catch(() => {})
  return saveQueue
}

async function saveWithTimeout(options) {
  const controller = new AbortController()
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort()
      reject(new Error('Expansion save timed out'))
    }, SAVE_TIMEOUT_MS)
  })
  try {
    // Bound the queue wait even if the transport fails to settle after abort.
    await Promise.race([
      csrfFetch('/creative_expanded_states/toggle', { ...options, signal: controller.signal }),
      timeout,
    ])
  } finally {
    clearTimeout(timer)
  }
}
