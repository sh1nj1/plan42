import csrfFetch from './csrf_fetch'

// Keep same-user writes ordered across Turbo controller replacements.
let saveQueue = Promise.resolve()

export function queueExpansionSave(userId, state) {
  saveQueue = saveQueue.then(() => {
    if (!userId || document.body.dataset.currentUserId !== userId) return

    return csrfFetch('/creative_expanded_states/toggle', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      // The cookie can change before Turbo renders the new user's body.
      body: JSON.stringify({ ...state, expected_user_id: userId }),
    })
  }).catch(() => {})
  return saveQueue
}
