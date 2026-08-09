import { collavreMountPath, creativeIdFromUrl } from "../lexical/creative_link_node"
import { WORKSPACE_FRAME_ID } from "./filter_navigation"

function clickedAnchor(event) {
  const target = event.target
  return target instanceof Element ? target.closest("a[href]") : null
}

function isCreativeCommentPath(path, mountPath) {
  const parsed = new URL(path, window.location.origin)
  const creativeBasePath = `${mountPath}/creatives`
  if (!parsed.pathname.startsWith(`${creativeBasePath}/`)) return false

  return /^\/\d+\/comments\/\d+$/.test(parsed.pathname.slice(creativeBasePath.length))
}

function shouldUseDefaultNavigation(event, anchor) {
  if (event.defaultPrevented || event.button !== 0) return true
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return true
  if (anchor.hasAttribute("download")) return true
  if (anchor.target && anchor.target !== "_self") return true
  if (anchor.closest('[data-turbo="false"]')) return true
  if (anchor.closest("[contenteditable], [data-lexical-editor-root]")) return true

  const turboFrame = anchor.dataset.turboFrame
  return Boolean(turboFrame && turboFrame !== WORKSPACE_FRAME_ID)
}

function workspaceCreativePath(href) {
  try {
    const url = new URL(href, window.location.href)
    if (url.origin !== window.location.origin) return null

    return `${url.pathname}${url.search}${url.hash}`
  } catch (_error) {
    return null
  }
}

export function handleCreativeLinkClick(event) {
  const anchor = clickedAnchor(event)
  if (!anchor || shouldUseDefaultNavigation(event, anchor)) return false

  const href = anchor.getAttribute("href")
  const path = workspaceCreativePath(href)
  const mountPath = collavreMountPath()
  if (!path || (!creativeIdFromUrl(path, mountPath) && !isCreativeCommentPath(path, mountPath))) return false

  const workspaceFrame = document.getElementById(WORKSPACE_FRAME_ID)
  if (!workspaceFrame || !window.Turbo?.visit) return false

  event.preventDefault()
  const action = anchor.dataset.turboAction || "advance"
  window.Turbo.visit(href, { action, frame: WORKSPACE_FRAME_ID })
  return true
}

document.addEventListener("click", handleCreativeLinkClick)
