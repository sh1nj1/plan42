// GNB Popup Manager
// Ensures only one GNB popup/panel is visible at a time.
// Each popup registers itself and dispatches 'gnb:popup-open' when opening.
// Other popups listen for this event and close themselves.

const EVENT_NAME = 'gnb:popup-open'

/**
 * Notify all other GNB popups that a popup is opening.
 * @param {string} id - Unique identifier for the popup being opened
 */
export function notifyPopupOpen(id) {
  document.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: { id } }))
}

/**
 * Register a close handler that fires when another popup opens.
 * @param {string} id - Unique identifier for this popup
 * @param {Function} closeFn - Function to call to close this popup
 * @returns {Function} Cleanup function to remove the listener
 */
export function onOtherPopupOpen(id, closeFn) {
  const handler = (event) => {
    if (event.detail.id !== id) {
      closeFn()
    }
  }
  document.addEventListener(EVENT_NAME, handler)
  return () => document.removeEventListener(EVENT_NAME, handler)
}
