// Shared UI hooks for the guide, kept outside the tree and popup controllers.
export function decorateTreeNode(link, row, node) {
  link.dataset.guideAnchor = 'tree.node'
  link.dataset.guideAnchorKey = String(node.id)
  row.appendChild(link)
  if (node.progress === undefined) return
  const progress = document.createElement('span')
  progress.className = 'creative-workspace-tree-progress'
  progress.textContent = `${Math.round(Number(node.progress) * 100)}%`
  row.appendChild(progress)
}

export function setWorkspacePanelOpen(controller, open) {
  const wasOpen = controller.element.classList.contains('is-open')
  controller.element.classList.toggle('is-open', open)
  controller.panelToggleTarget.setAttribute('aria-expanded', String(open))
  if (wasOpen && !open) {
    controller.element.dispatchEvent(new CustomEvent('workspace-tree:panel-closed', { bubbles: true }))
  }
}

export function openPendingChat(controller) {
  if (controller.element.dataset.autoOpen !== 'true') return false
  delete controller.element.dataset.autoOpen
  requestAnimationFrame(() => controller.openForCreative())
  return true
}

export function openInitialChat(controller) {
  if (controller.isFullscreen()) {
    controller._syncFullscreenUI(true)
    requestAnimationFrame(() => controller.openForCreative())
  } else if (controller.isDocked()) {
    controller.enterDockedMode()
  } else if (!controller.openPendingChat()) {
    controller.openFromUrl()
  }
}
