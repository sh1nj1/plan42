import React, {useCallback, useEffect, useMemo, useRef} from "react"
import {DecoratorNode} from "lexical"
import {useLexicalComposerContext} from "@lexical/react/LexicalComposerContext"
import {useLexicalNodeSelection} from "@lexical/react/useLexicalNodeSelection"
import {mergeRegister} from "@lexical/utils"
import {
  $getNodeByKey,
  COMMAND_PRIORITY_LOW,
  KEY_BACKSPACE_COMMAND,
  KEY_DELETE_COMMAND
} from "lexical"

import {
  sanitizeAttachmentPayload,
  attachmentPayloadFromAttachmentElement,
  attachmentPayloadFromFigure,
  attachmentPayloadToHTMLElement,
  ensureSgid,
  formatFileSize
} from "./attachment_payload"

const TYPE = "action-text-attachment"

const STATUS_READY = "ready"
const STATUS_UPLOADING = "uploading"
const STATUS_ERROR = "error"

export class ActionTextAttachmentNode extends DecoratorNode {
  constructor(payload, key) {
    super(key)
    this.__payload = sanitizeAttachmentPayload(payload)
  }

  static getType() {
    return TYPE
  }

  static clone(node) {
    return new ActionTextAttachmentNode(node.__payload, node.__key)
  }

  static importJSON(serializedNode) {
    return new ActionTextAttachmentNode(serializedNode.payload ?? {}, serializedNode.key)
  }

  exportJSON() {
    return {
      type: TYPE,
      version: 1,
      payload: this.__payload
    }
  }

  static importDOM() {
    return {
      "action-text-attachment": (domNode) => ({
        conversion: (node) => {
          const payload = attachmentPayloadFromAttachmentElement(node)
          return payload ? {node: new ActionTextAttachmentNode(payload)} : null
        },
        priority: 1
      }),
      figure: (domNode) => ({
        conversion: (node) => {
          const payload = attachmentPayloadFromFigure(node)
          return payload ? {node: new ActionTextAttachmentNode(payload)} : null
        },
        priority: 0
      })
    }
  }

  exportDOM() {
    const {element} = attachmentPayloadToHTMLElement(this.__payload)
    return {element}
  }

  createDOM() {
    const container = document.createElement("div")
    container.className = "lexical-attachment-block"
    return container
  }

  updateDOM() {
    return false
  }

  getPayload() {
    return this.__payload
  }

  setPayload(updates) {
    const writable = this.getWritable()
    writable.__payload = sanitizeAttachmentPayload({...writable.__payload, ...updates})
  }

  setCaption(caption) {
    this.setPayload({caption})
  }

  setDimensions(width, height) {
    this.setPayload({width, height})
  }

  setProgress(progress) {
    this.setPayload({progress: Math.max(0, Math.min(100, progress || 0))})
  }

  setLocalPreview(localUrl) {
    this.setPayload({localUrl})
  }

  markUploading(updates = {}) {
    this.setPayload({
      ...updates,
      status: STATUS_UPLOADING,
      progress: 0,
      previewable:
        updates.previewable !== undefined
          ? !!updates.previewable
          : this.__payload.previewable
    })
  }

  applyUploadResult(result) {
    this.setPayload({
      ...result,
      status: STATUS_READY,
      progress: 100
    })
  }

  markUploadError(message) {
    this.setPayload({
      status: STATUS_ERROR,
      progress: 0,
      error: message || "Upload failed"
    })
  }

  markUploaded() {
    this.setPayload({status: STATUS_READY, progress: 100})
  }

  clearLocalUrl() {
    this.setPayload({localUrl: null})
  }

  getTextContent() {
    return " "
  }

  isInline() {
    return false
  }

  decorate() {
    return React.createElement(AttachmentComponent, {
      nodeKey: this.getKey(),
      payload: this.__payload
    })
  }
}

export function $createActionTextAttachmentNode(payload = {}) {
  return new ActionTextAttachmentNode(payload)
}

export function $isActionTextAttachmentNode(node) {
  return node instanceof ActionTextAttachmentNode
}

function isBlobUrl(url) {
  return typeof url === "string" && url.startsWith("blob:")
}

function AttachmentComponent({payload, nodeKey}) {
  const [editor] = useLexicalComposerContext()
  const [isSelected, setSelected, clearSelection] = useLexicalNodeSelection(nodeKey)
  const imageRef = useRef(null)

  const className = useMemo(() => {
    const classes = ["lexical-attachment"]
    if (payload.previewable) classes.push("lexical-attachment--image")
    if (isSelected) classes.push("is-selected")
    if (payload.status === STATUS_UPLOADING) classes.push("is-uploading")
    if (payload.status === STATUS_ERROR) classes.push("is-error")
    return classes.join(" ")
  }, [isSelected, payload.previewable, payload.status])

  const removeNode = useCallback(() => {
    editor.update(() => {
      const node = $getNodeByKey(nodeKey)
      if ($isActionTextAttachmentNode(node)) {
        node.remove()
      }
    })
  }, [editor, nodeKey])

  useEffect(() => {
    return mergeRegister(
      editor.registerCommand(
        KEY_DELETE_COMMAND,
        (event) => {
          if (isSelected) {
            event?.preventDefault()
            removeNode()
            return true
          }
          return false
        },
        COMMAND_PRIORITY_LOW
      ),
      editor.registerCommand(
        KEY_BACKSPACE_COMMAND,
        (event) => {
          if (isSelected) {
            event?.preventDefault()
            removeNode()
            return true
          }
          return false
        },
        COMMAND_PRIORITY_LOW
      )
    )
  }, [editor, isSelected, removeNode])

  useEffect(() => () => {
    if (isBlobUrl(payload.localUrl)) {
      URL.revokeObjectURL(payload.localUrl)
    }
  }, [payload.localUrl])

  const selectNode = useCallback(
    (event) => {
      if (event.target.closest("input, textarea, button, a")) return
      event.preventDefault()
      if (!event.shiftKey) {
        clearSelection()
        setSelected(true)
      } else {
        setSelected(!isSelected)
      }
    },
    [clearSelection, isSelected, setSelected]
  )

  const handleCaptionChange = useCallback(
    (event) => {
      const nextCaption = event.target.value
      editor.update(() => {
        const node = $getNodeByKey(nodeKey)
        if ($isActionTextAttachmentNode(node)) {
          node.setCaption(nextCaption)
        }
      })
    },
    [editor, nodeKey]
  )

  const startResize = useCallback(
    (event) => {
      if (!payload.previewable) return
      event.preventDefault()
      const img = imageRef.current
      if (!img) return
      const rect = img.getBoundingClientRect()
      const ratio = rect.width && rect.height ? rect.width / rect.height : 1
      const startWidth = rect.width
      const startX = event.clientX

      const handleMove = (moveEvent) => {
        const delta = moveEvent.clientX - startX
        const nextWidth = Math.max(80, Math.round(startWidth + delta))
        const nextHeight = Math.round(nextWidth / ratio)
        editor.update(() => {
          const node = $getNodeByKey(nodeKey)
          if ($isActionTextAttachmentNode(node)) {
            node.setDimensions(nextWidth, nextHeight)
          }
        })
      }

      const handleUp = () => {
        document.removeEventListener("pointermove", handleMove)
        document.removeEventListener("pointerup", handleUp)
      }

      document.addEventListener("pointermove", handleMove)
      document.addEventListener("pointerup", handleUp)
    },
    [editor, nodeKey, payload.previewable]
  )

  const children = []

  children.push(
    React.createElement(
      "button",
      {
        type: "button",
        className: "lexical-attachment__remove",
        onMouseDown: (event) => event.preventDefault(),
        onClick: (event) => {
          event.preventDefault()
          removeNode()
        },
        "aria-label": "Remove attachment"
      },
      "×"
    )
  )

  if (payload.status === STATUS_UPLOADING) {
    children.push(
      React.createElement(
        "div",
        {className: "lexical-attachment__overlay"},
        React.createElement(
          "div",
          {className: "lexical-attachment__progress"},
          `Uploading… ${Math.round(payload.progress || 0)}%`
        )
      )
    )
  }

  if (payload.status === STATUS_ERROR) {
    children.push(
      React.createElement(
        "div",
        {className: "lexical-attachment__overlay lexical-attachment__overlay--error"},
        React.createElement("div", null, "Upload failed. Remove and try again.")
      )
    )
  }

  const figureChildren = []

  if (payload.previewable && (payload.localUrl || payload.url)) {
    figureChildren.push(
      React.createElement("img", {
        ref: imageRef,
        src: payload.localUrl || payload.url,
        alt: payload.caption || payload.filename || "",
        style: {
          width: payload.width ? `${Math.round(payload.width)}px` : undefined,
          height: payload.height ? `${Math.round(payload.height)}px` : undefined
        }
      })
    )
  } else {
    const infoChildren = []
    if (payload.url) {
      infoChildren.push(
        React.createElement(
          "a",
          {
            href: payload.url,
            target: "_blank",
            rel: "noopener",
            className: "lexical-attachment__file-name",
            onClick: (event) => event.stopPropagation()
          },
          payload.filename || "Attachment"
        )
      )
    } else {
      infoChildren.push(
        React.createElement(
          "div",
          {className: "lexical-attachment__file-name"},
          payload.filename || "Attachment"
        )
      )
    }
    if (Number.isFinite(payload.filesize)) {
      infoChildren.push(
        React.createElement(
          "div",
          {className: "lexical-attachment__file-size"},
          formatFileSize(payload.filesize)
        )
      )
    }

    figureChildren.push(
      React.createElement(
        "div",
        {className: "lexical-attachment__file"},
        React.createElement(
          "div",
          {className: "lexical-attachment__file-icon", "aria-hidden": "true"},
          "📎"
        ),
        React.createElement(
          "div",
          {className: "lexical-attachment__file-info"},
          ...infoChildren
        )
      )
    )
  }

  const captionChildren = [
    React.createElement("input", {
      type: "text",
      className: "lexical-attachment__caption-input",
      value: payload.caption || "",
      placeholder: payload.previewable ? "Add caption" : "Describe attachment",
      onChange: handleCaptionChange,
      onClick: (event) => event.stopPropagation(),
      onFocus: (event) => event.stopPropagation()
    })
  ]

  if (payload.previewable && Number.isFinite(payload.filesize)) {
    captionChildren.push(
      React.createElement(
        "span",
        {className: "lexical-attachment__caption-size"},
        formatFileSize(payload.filesize)
      )
    )
  }

  figureChildren.push(React.createElement("figcaption", null, ...captionChildren))

  children.push(React.createElement("figure", null, ...figureChildren))

  if (payload.previewable) {
    children.push(
      React.createElement("div", {
        className: "lexical-attachment__resize-handle",
        role: "presentation",
        onPointerDown: startResize
      })
    )
  }

  return React.createElement(
    "div",
    {className, contentEditable: false, onClick: selectNode},
    ...children
  )
}
