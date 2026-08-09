import { creativeIdFromUrl } from "../lexical/creative_link_node"
import { WORKSPACE_FRAME_ID } from "./filter_navigation"

function clickedAnchor(event) {
  const target = event.target
  return target instanceof Element ? target.closest("a[href]") : null
}

function shouldUseDefaultNavigation(event, anchor) {
  if (event.defaultPrevented || event.button !== 0) return true
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return true
  if (anchor.hasAttribute("download")) return true
  if (anchor.target && anchor.target !== "_self") return true
  if (anchor.closest('[data-turbo="false"]')) return true

  const turboFrame = anchor.dataset.turboFrame
  return Boolean(turboFrame && turboFrame !== WORKSPACE_FRAME_ID)
}

export function handleCreativeLinkClick(event) {
  const anchor = clickedAnchor(event)
  if (!anchor || shouldUseDefaultNavigation(event, anchor)) return false

  const href = anchor.getAttribute("href")
  if (!creativeIdFromUrl(href)) return false

  const workspaceFrame = document.getElementById(WORKSPACE_FRAME_ID)
  if (!workspaceFrame || !window.Turbo?.visit) return false

  event.preventDefault()
  window.Turbo.visit(href, { action: "advance", frame: WORKSPACE_FRAME_ID })
  return true
}

document.addEventListener("click", handleCreativeLinkClick)
