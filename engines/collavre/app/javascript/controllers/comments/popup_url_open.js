// Keep deferred URL opens and their cleanup together across controller disconnects.
export function scheduleOpenFromUrl(controller) {
  controller.openFromUrlFrame = requestAnimationFrame(() => {
    controller.openFromUrlFrame = null
    if (controller.element.isConnected) controller.openFromUrl()
  })
}

export function clearPendingOpenFromUrl(controller) {
  if (controller.openFromUrlFrame != null) {
    cancelAnimationFrame(controller.openFromUrlFrame)
    controller.openFromUrlFrame = null
  }
  if (controller.openFromUrlObserver) {
    controller.openFromUrlObserver.disconnect()
    controller.openFromUrlObserver = null
  }
  if (controller.openFromUrlTimeout) {
    window.clearTimeout(controller.openFromUrlTimeout)
    controller.openFromUrlTimeout = null
  }
}
