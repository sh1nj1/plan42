import { createSubscription } from './cable'

const EDITING_TIMEOUT = 5000

/**
 * Subscribe to real-time creative tree updates.
 *
 * @param {number|string} rootId - The root creative ID to subscribe to
 * @param {object} callbacks
 * @param {function} callbacks.onConnected - Called when connected
 * @param {function} callbacks.onDisconnected - Called when disconnected
 * @param {function} callbacks.onPresence - Called with { user_ids: [...] }
 * @param {function} callbacks.onEditing - Called with { creative_id, user_id, user_name, avatar_url }
 * @param {function} callbacks.onStoppedEditing - Called with { creative_id, user_id }
 * @returns {object} subscription object with .unsubscribe() and action methods
 */
export function subscribeToCreatives(rootId, callbacks = {}) {
  const editingTimers = {}

  const subscription = createSubscription(
    { channel: 'Collavre::CreativesChannel', root_id: rootId },
    {
      connected() {
        callbacks.onConnected?.()
      },
      disconnected() {
        callbacks.onDisconnected?.()
      },
      received(data) {
        // NOTE: CRUD sync is handled via Turbo Streams (refresh_creative_tree action),
        // not through this ActionCable channel. This channel handles only presence + editing.

        if (data.presence) {
          callbacks.onPresence?.(data.presence)
        }

        if (data.editing) {
          const { creative_id, user_id } = data.editing
          // Auto-clear editing after timeout
          const timerKey = `${creative_id}-${user_id}`
          if (editingTimers[timerKey]) clearTimeout(editingTimers[timerKey])
          editingTimers[timerKey] = setTimeout(() => {
            callbacks.onStoppedEditing?.({ creative_id, user_id })
            delete editingTimers[timerKey]
          }, EDITING_TIMEOUT)
          callbacks.onEditing?.(data.editing)
        }

        if (data.stopped_editing) {
          const { creative_id, user_id } = data.stopped_editing
          const timerKey = `${creative_id}-${user_id}`
          if (editingTimers[timerKey]) {
            clearTimeout(editingTimers[timerKey])
            delete editingTimers[timerKey]
          }
          callbacks.onStoppedEditing?.(data.stopped_editing)
        }
      },
    },
  )

  // Extend subscription with convenience methods
  subscription.sendEditing = (creativeId) => {
    subscription.perform('editing', { creative_id: creativeId })
  }

  subscription.sendStoppedEditing = (creativeId) => {
    subscription.perform('stopped_editing', { creative_id: creativeId })
  }

  subscription.cleanup = () => {
    Object.values(editingTimers).forEach((timer) => clearTimeout(timer))
    subscription.unsubscribe()
  }

  return subscription
}
