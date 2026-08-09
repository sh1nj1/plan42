import { LinkNode } from "@lexical/link"
import { $applyNodeReplacement } from "lexical"

const WORKSPACE_FRAME_ID = "creative-workspace-content"

function normalizedMountPath(mountPath) {
  const value = String(mountPath || "").trim()
  if (!value || value === "/") return ""

  return `/${value.replace(/^\/+|\/+$/g, "")}`
}

export function collavreMountPath() {
  return normalizedMountPath(
    document.getElementById(WORKSPACE_FRAME_ID)?.dataset.collavreMountPath
  )
}

export function creativeIdFromUrl(url, mountPath = collavreMountPath()) {
  const value = String(url || "")
  if (!value.startsWith("/") || value.startsWith("//")) return null

  const parsed = new URL(value, "http://collavre.local")
  const creativeBasePath = `${normalizedMountPath(mountPath)}/creatives`
  const showPath = parsed.pathname.startsWith(`${creativeBasePath}/`)
    ? parsed.pathname.slice(creativeBasePath.length)
    : ""
  const showMatch = showPath.match(/^\/(\d+)$/)
  if (showMatch) return Number(showMatch[1])

  if (parsed.pathname !== creativeBasePath) return null

  const id = parsed.searchParams.get("id")
  return /^\d+$/.test(id || "") ? Number(id) : null
}

export class CreativeLinkNode extends LinkNode {
  __creativeId

  static getType() {
    return "creative-link"
  }

  static clone(node) {
    return new CreativeLinkNode(
      node.__url,
      node.__creativeId,
      { rel: node.__rel, target: node.__target, title: node.__title },
      node.__key
    )
  }

  constructor(url = "", creativeId = null, attributes = {}, key) {
    super(url, attributes, key)
    this.__creativeId = Number(creativeId || creativeIdFromUrl(url)) || null
  }

  createDOM(config) {
    const element = super.createDOM(config)
    if (this.__creativeId) element.dataset.creativeId = String(this.__creativeId)
    return element
  }

  updateDOM(prevNode, element, config) {
    super.updateDOM(prevNode, element, config)
    const creativeId = this.getCreativeId()
    if (creativeId) {
      element.dataset.creativeId = String(creativeId)
    } else {
      delete element.dataset.creativeId
    }
    return false
  }

  static importDOM() {
    return {
      a: (element) => {
        const creativeId = Number(element.dataset.creativeId) || creativeIdFromUrl(element.getAttribute("href"))
        if (!creativeId) return null

        return {
          conversion: () => ({
            node: $createCreativeLinkNode(
              element.getAttribute("href") || `/creatives/${creativeId}`,
              creativeId,
              {
                rel: element.getAttribute("rel"),
                target: element.getAttribute("target"),
                title: element.getAttribute("title")
              }
            )
          }),
          priority: 2
        }
      }
    }
  }

  static importJSON(serializedNode) {
    return $createCreativeLinkNode(
      serializedNode.url,
      serializedNode.creativeId,
      serializedNode
    ).updateFromJSON(serializedNode)
  }

  exportJSON() {
    return {
      ...super.exportJSON(),
      creativeId: this.getCreativeId(),
      type: "creative-link",
      version: 1
    }
  }

  getCreativeId() {
    return this.getLatest().__creativeId
  }
}

export function $createCreativeLinkNode(url, creativeId, attributes) {
  return $applyNodeReplacement(new CreativeLinkNode(url, creativeId, attributes))
}

export function $isCreativeLinkNode(node) {
  return node instanceof CreativeLinkNode
}
