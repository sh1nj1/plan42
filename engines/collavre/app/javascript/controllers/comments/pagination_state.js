export function resetPaginationState(controller) {
  controller.loadingOlderPromise = null
  controller.pendingPreviousMessageNavigation = null
  controller.loadingOlder = false
  controller.loadingNewer = false
  controller.allOlderLoaded = false
  controller.allNewerLoaded = true
}

export function beginCommentsReload(controller) {
  // Block pagination against the old DOM until the replacement is rendered.
  // Incrementing the version also invalidates any in-flight page requests.
  controller.loadingOlderPromise = null
  controller.pendingPreviousMessageNavigation = null
  controller.loadingOlder = true
  controller.loadingNewer = true
  controller.initialLoadComplete = false
  controller.prevMsgNavigator.reset()
  return ++controller._loadCommentsVersion
}
