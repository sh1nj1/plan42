import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react"
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

const TYPE = "action-text-attachment"

const STATUS_READY = "ready"
const STATUS_UPLOADING = "uploading"
const STATUS_ERROR = "error"

function isImageContentType(contentType = "") {
  return /^image\//i.test(contentType)
}

function roundDimension(value) {
  if (typeof value !== "number") return null
  if (!Number.isFinite(value)) return null
  return Math.max(1, Math.round(value))
}

function isBlobUrl(value) {
  return typeof value === "string" && value.startsWith("blob:")
}

function formatFileSize(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return ""
  const units = ["B", "KB", "MB", "GB", "TB"]
  let size = bytes
  let unitIndex = 0
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024
    unitIndex += 1
  }
  return `${size % 1 === 0 ? size : size.toFixed(1)} ${units[unitIndex]}`
}

function extractTextContent(element) {
  if (!element) return ""
  return element.textContent?.trim() || ""
}

function parseDimension(value) {
  if (!value) return null
  const parsed = parseFloat(value)
  if (!Number.isFinite(parsed)) return null
  return parsed
}

export class ActionTextAttachmentNode extends DecoratorNode {
  constructor(payload, key) {
    super(key)
    this.__payload = {
      sgid: payload?.sgid || null,
      url: payload?.url || "",
      filename: payload?.filename || "",
      contentType: payload?.contentType || "",
      filesize: payload?.filesize || null,
      caption: payload?.caption || "",
      previewable:
        payload?.previewable !== undefined
          ? !!payload.previewable
          : isImageContentType(payload?.contentType),
      width: payload?.width ?? null,
      height: payload?.height ?? null,
      status: payload?.status || STATUS_READY,
      progress:
        payload?.progress !== undefined
          ? payload.progress
          : payload?.status === STATUS_READY
            ? 100
            : 0,
      localUrl: payload?.localUrl || null,
      error: payload?.error || null
    }
  }

  static getType() {
    return TYPE
  }

  static clone(node) {
    return new ActionTextAttachmentNode({...node.__payload}, node.__key)
  }

  static importJSON(serializedNode) {
    return new ActionTextAttachmentNode(serializedNode.payload ?? {}, serializedNode.key)
  }

  exportJSON() {
    const {localUrl, error, ...rest} = this.__payload
    return {
      type: TYPE,
      version: 1,
      payload: {
        ...rest,
        localUrl: null,
        error: error ? String(error) : null
      }
    }
  }

  static importDOM() {
    return {
      "action-text-attachment": (domNode) => ({
        conversion: convertActionTextAttachmentElement,
        priority: 1
      })
    }
  }

  exportDOM() {
    if (this.__payload.status !== STATUS_READY || !this.__payload.sgid) {
      const placeholder = document.createElement("span")
      placeholder.setAttribute("data-attachment", "pending")
      placeholder.textContent = this.__payload.error
        ? `Attachment failed: ${this.__payload.error}`
        : `Attachment uploading: ${this.__payload.filename || "pending"}`
      return {element: placeholder}
    }

    const element = document.createElement("action-text-attachment")
    element.setAttribute("sgid", this.__payload.sgid)

    if (this.__payload.contentType) {
      element.setAttribute("content-type", this.__payload.contentType)
    }
    if (this.__payload.url) {
      element.setAttribute("url", this.__payload.url)
    }
    if (this.__payload.filename) {
      element.setAttribute("filename", this.__payload.filename)
    }
    if (Number.isFinite(this.__payload.filesize)) {
      element.setAttribute("filesize", String(this.__payload.filesize))
    }
    if (this.__payload.caption) {
      element.setAttribute("caption", this.__payload.caption)
    }
    if (this.__payload.previewable) {
      element.setAttribute("previewable", "true")
    }
    const widthValue = roundDimension(this.__payload.width)
    const heightValue = roundDimension(this.__payload.height)
    if (widthValue) {
      element.setAttribute("data-width", String(widthValue))
    }
    if (heightValue) {
      element.setAttribute("data-height", String(heightValue))
    }

    const figure = document.createElement("figure")
    figure.className = `attachment ${
      this.__payload.previewable ? "attachment--preview" : "attachment--file"
    }`
    if (widthValue) {
      figure.style.width = `${widthValue}px`
    }

    if (this.__payload.previewable) {
      const img = document.createElement("img")
      img.src = this.__payload.url
      img.alt = this.__payload.caption || this.__payload.filename || ""
      if (widthValue) {
        img.style.width = `${widthValue}px`
        img.setAttribute("data-width", String(widthValue))
      }
      if (heightValue) {
        img.style.height = `${heightValue}px`
        img.setAttribute("data-height", String(heightValue))
      }
      figure.appendChild(img)
    } else {
      const wrapper = document.createElement("div")
      wrapper.className = "attachment__file"
      const icon = document.createElement("span")
      icon.className = "attachment__file-icon"
      icon.textContent = "📎"
      const info = document.createElement("div")
      info.className = "attachment__file-info"
      const nameEl = document.createElement("span")
      nameEl.className = "attachment__name"
      nameEl.textContent = this.__payload.filename || "Attachment"
      info.appendChild(nameEl)
      if (Number.isFinite(this.__payload.filesize)) {
        const sizeEl = document.createElement("span")
        sizeEl.className = "attachment__size"
        sizeEl.textContent = formatFileSize(this.__payload.filesize)
        info.appendChild(sizeEl)
      }
      wrapper.appendChild(icon)
      wrapper.appendChild(info)
      figure.appendChild(wrapper)
    }

    const shouldRenderCaption =
      this.__payload.caption || !this.__payload.previewable || Number.isFinite(this.__payload.filesize)
    if (shouldRenderCaption) {
      const figcaption = document.createElement("figcaption")
      figcaption.className = "attachment__caption"
      if (this.__payload.caption) {
        const captionSpan = document.createElement("span")
        captionSpan.className = "attachment__name"
        captionSpan.textContent = this.__payload.caption
        figcaption.appendChild(captionSpan)
      } else if (this.__payload.filename) {
        const captionSpan = document.createElement("span")
        captionSpan.className = "attachment__name"
        captionSpan.textContent = this.__payload.filename
        figcaption.appendChild(captionSpan)
      }
      if (Number.isFinite(this.__payload.filesize)) {
        const sizeSpan = document.createElement("span")
        sizeSpan.className = "attachment__size"
        sizeSpan.textContent = formatFileSize(this.__payload.filesize)
        figcaption.appendChild(sizeSpan)
      }
      figure.appendChild(figcaption)
    }

    element.appendChild(figure)
    return {element}
  }

  createDOM() {
    const div = document.createElement("div")
    div.className = "lexical-attachment-block"
    return div
  }

  updateDOM() {
    return false
  }

  getPayload() {
    return this.__payload
  }

  setPayload(updates) {
    const writable = this.getWritable()
    writable.__payload = {...writable.__payload, ...updates}
  }

  setCaption(caption) {
    this.setPayload({caption: caption || ""})
  }

  setDimensions(width, height) {
    this.setPayload({
      width: width ?? null,
      height: height ?? null
    })
  }

  setProgress(progress) {
    const clamped = Math.max(0, Math.min(100, progress || 0))
    this.setPayload({progress: clamped})
  }

  markUploading({
    filename,
    contentType,
    filesize,
    previewable,
    localUrl
  }) {
    this.setPayload({
      status: STATUS_UPLOADING,
      progress: 0,
      filename: filename || this.__payload.filename,
      contentType: contentType || this.__payload.contentType,
      filesize: filesize ?? this.__payload.filesize,
      previewable:
        previewable !== undefined
          ? !!previewable
          : isImageContentType(contentType || this.__payload.contentType),
      localUrl: localUrl || this.__payload.localUrl,
      error: null
    })
  }

  applyUploadResult({
    sgid,
    url,
    filename,
    contentType,
    filesize
  }) {
    this.setPayload({
      sgid,
      url,
      filename: filename || this.__payload.filename,
      contentType: contentType || this.__payload.contentType,
      filesize: filesize ?? this.__payload.filesize,
      status: STATUS_READY,
      progress: 100,
      error: null
    })
  }

  markUploadError(errorMessage) {
    this.setPayload({
      status: STATUS_ERROR,
      error: errorMessage || "Upload failed",
      progress: 0
    })
  }

  clearLocalUrl() {
    this.setPayload({localUrl: null})
  }

  setLocalPreview(localUrl) {
    this.setPayload({localUrl: localUrl || null})
  }

  getTextContent() {
    return " "
  }

  isInline() {
    return false
  }

  decorate() {
    return (
      <ActionTextAttachmentComponent
        payload={this.__payload}
        nodeKey={this.getKey()}
      />
    )
  }
}

export function $createActionTextAttachmentNode(payload = {}) {
  return new ActionTextAttachmentNode(payload)
}

export function $isActionTextAttachmentNode(node) {
  return node instanceof ActionTextAttachmentNode
}

function convertActionTextAttachmentElement(domNode) {
  const element = domNode
  const payload = {
    sgid: element.getAttribute("sgid"),
    url: element.getAttribute("url") || "",
    filename: element.getAttribute("filename") || "",
    contentType: element.getAttribute("content-type") || "",
    filesize: parseInt(element.getAttribute("filesize") || "", 10) || null,
    caption: element.getAttribute("caption") || "",
    previewable: element.getAttribute("previewable") === "true"
  }

  const widthAttr = parseDimension(element.getAttribute("data-width"))
  const heightAttr = parseDimension(element.getAttribute("data-height"))
  if (widthAttr) payload.width = widthAttr
  if (heightAttr) payload.height = heightAttr

  if (!payload.previewable && isImageContentType(payload.contentType)) {
    payload.previewable = true
  }

  const figure = element.querySelector("figure")
  if (figure) {
    const img = figure.querySelector("img")
    if (img) {
      payload.previewable = true
      if (!payload.url) {
        payload.url = img.getAttribute("src") || ""
      }
      const imgWidth = parseDimension(img.getAttribute("data-width")) || parseDimension(img.style.width)
      const imgHeight = parseDimension(img.getAttribute("data-height")) || parseDimension(img.style.height)
      if (imgWidth && !payload.width) payload.width = imgWidth
      if (imgHeight && !payload.height) payload.height = imgHeight
      const alt = img.getAttribute("alt")
      if (!payload.caption && alt) payload.caption = alt
    }
    const caption = figure.querySelector("figcaption")
    if (caption && !payload.caption) {
      payload.caption = extractTextContent(caption)
    }
  }

  payload.status = STATUS_READY
  payload.progress = 100

  const node = $createActionTextAttachmentNode(payload)
  return {node}
}

function ActionTextAttachmentComponent({payload, nodeKey}) {
  const [editor] = useLexicalComposerContext()
  const [isSelected, setSelected, clearSelection] = useLexicalNodeSelection(nodeKey)
  const imageRef = useRef(null)
  const [dimensions, setDimensions] = useState(() => ({
    width: payload.width || null,
    height: payload.height || null
  }))
  const [naturalRatio, setNaturalRatio] = useState(null)
  const resizingRef = useRef({
    active: false,
    startX: 0,
    startWidth: 0,
    startHeight: 0,
    ratio: 1
  })

  const isImage = payload.previewable || isImageContentType(payload.contentType)
  const activeSrc = payload.status === STATUS_READY && payload.url ? payload.url : payload.localUrl || payload.url
  const imageSrc = activeSrc || null

  useEffect(() => {
    setDimensions({width: payload.width || null, height: payload.height || null})
  }, [payload.width, payload.height])

  useEffect(() => {
    return () => {
      if (isBlobUrl(payload.localUrl)) {
        URL.revokeObjectURL(payload.localUrl)
      }
    }
  }, [payload.localUrl])

  useEffect(() => {
    if (payload.status === STATUS_READY && payload.localUrl) {
      if (isBlobUrl(payload.localUrl)) {
        URL.revokeObjectURL(payload.localUrl)
      }
      editor.update(() => {
        const node = $getNodeByKey(nodeKey)
        if (node instanceof ActionTextAttachmentNode) {
          node.clearLocalUrl()
        }
      })
    }
  }, [editor, nodeKey, payload.localUrl, payload.status])

  useEffect(() => {
    if (!isImage || !imageSrc) return
    let cancelled = false
    const img = new Image()
    img.onload = () => {
      if (cancelled) return
      const ratio = img.naturalWidth / img.naturalHeight || 1
      setNaturalRatio(ratio)
      if (!payload.width || !payload.height) {
        const width = Math.min(img.naturalWidth, 640)
        const height = Math.round(width / ratio)
        setDimensions({width, height})
        editor.update(() => {
          const node = $getNodeByKey(nodeKey)
          if (node instanceof ActionTextAttachmentNode) {
            node.setDimensions(width, height)
          }
        })
      }
    }
    img.src = imageSrc
    return () => {
      cancelled = true
    }
  }, [editor, imageSrc, isImage, nodeKey, payload.height, payload.width])

  useEffect(() => {
    return mergeRegister(
      editor.registerCommand(
        KEY_DELETE_COMMAND,
        (event) => {
          if (isSelected) {
            event?.preventDefault()
            editor.update(() => {
              const node = $getNodeByKey(nodeKey)
              if (node instanceof ActionTextAttachmentNode) {
                node.remove()
              }
            })
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
            editor.update(() => {
              const node = $getNodeByKey(nodeKey)
              if (node instanceof ActionTextAttachmentNode) {
                node.remove()
              }
            })
            return true
          }
          return false
        },
        COMMAND_PRIORITY_LOW
      )
    )
  }, [editor, isSelected, nodeKey])

  const selectNode = useCallback(
    (event) => {
      if (event.target.closest("input, textarea, button")) return
      event.preventDefault()
      event.stopPropagation()
      if (!event.shiftKey) {
        clearSelection(event)
        setSelected(true, event)
      } else {
        setSelected(!isSelected, event)
      }
    },
    [clearSelection, isSelected, setSelected]
  )

  const handleCaptionChange = useCallback(
    (event) => {
      const nextCaption = event.target.value
      editor.update(() => {
        const node = $getNodeByKey(nodeKey)
        if (node instanceof ActionTextAttachmentNode) {
          node.setCaption(nextCaption)
        }
      })
    },
    [editor, nodeKey]
  )

  const handleRemove = useCallback(
    (event) => {
      event.preventDefault()
      editor.update(() => {
        const node = $getNodeByKey(nodeKey)
        if (node instanceof ActionTextAttachmentNode) {
          node.remove()
        }
      })
    },
    [editor, nodeKey]
  )

  const startResize = useCallback(
    (event) => {
      if (!isImage) return
      event.preventDefault()
      event.stopPropagation()
      const imageEl = imageRef.current
      if (!imageEl) return
      const rect = imageEl.getBoundingClientRect()
      const ratio = naturalRatio || rect.width / rect.height || 1
      resizingRef.current = {
        active: true,
        startX: event.clientX,
        startWidth: rect.width,
        startHeight: rect.height,
        ratio
      }
      const handleMove = (moveEvent) => {
        if (!resizingRef.current.active) return
        moveEvent.preventDefault()
        const deltaX = moveEvent.clientX - resizingRef.current.startX
        const nextWidth = Math.max(80, resizingRef.current.startWidth + deltaX)
        const nextHeight = Math.round(nextWidth / resizingRef.current.ratio)
        setDimensions({width: nextWidth, height: nextHeight})
      }
      const handleUp = (upEvent) => {
        if (!resizingRef.current.active) return
        upEvent.preventDefault()
        const deltaX = upEvent.clientX - resizingRef.current.startX
        const nextWidth = Math.max(80, resizingRef.current.startWidth + deltaX)
        const nextHeight = Math.round(nextWidth / resizingRef.current.ratio)
        resizingRef.current.active = false
        document.removeEventListener("pointermove", handleMove)
        document.removeEventListener("pointerup", handleUp)
        editor.update(() => {
          const node = $getNodeByKey(nodeKey)
          if (node instanceof ActionTextAttachmentNode) {
            node.setDimensions(nextWidth, nextHeight)
          }
        })
      }
      document.addEventListener("pointermove", handleMove)
      document.addEventListener("pointerup", handleUp)
    },
    [editor, isImage, naturalRatio, nodeKey]
  )

  const className = useMemo(() => {
    const classes = ["lexical-attachment"]
    if (isImage) classes.push("lexical-attachment--image")
    if (isSelected) classes.push("is-selected")
    if (payload.status === STATUS_UPLOADING) classes.push("is-uploading")
    if (payload.status === STATUS_ERROR) classes.push("is-error")
    return classes.join(" ")
  }, [isImage, isSelected, payload.status])

  const sizeStyle = useMemo(() => {
    if (!isImage) return undefined
    const style = {}
    if (dimensions.width) style.width = `${Math.round(dimensions.width)}px`
    if (dimensions.height) style.height = `${Math.round(dimensions.height)}px`
    return style
  }, [dimensions.height, dimensions.width, isImage])

  return (
    <div className={className} contentEditable={false} onClick={selectNode}>
      <button
        type="button"
        className="lexical-attachment__remove"
        onMouseDown={(event) => event.preventDefault()}
        onClick={handleRemove}
        aria-label="Remove attachment"
      >
        ×
      </button>
      {payload.status === STATUS_UPLOADING && (
        <div className="lexical-attachment__overlay">
          <div className="lexical-attachment__progress">
            Uploading… {Math.round(payload.progress || 0)}%
          </div>
        </div>
      )}
      {payload.status === STATUS_ERROR && (
        <div className="lexical-attachment__overlay lexical-attachment__overlay--error">
          <div>Upload failed. Remove and try again.</div>
        </div>
      )}
      <figure style={isImage ? sizeStyle : undefined}>
      {isImage ? (
        imageSrc ? (
          <img
            ref={imageRef}
            src={imageSrc}
            alt={payload.caption || payload.filename || ""}
            style={sizeStyle}
          />
        ) : (
          <div
            className="lexical-attachment__image-placeholder"
            aria-label="Image uploading"
            style={sizeStyle}
          />
        )
      ) : (
          <div className="lexical-attachment__file">
            <div className="lexical-attachment__file-icon" aria-hidden="true">
              📎
            </div>
            <div className="lexical-attachment__file-info">
              <div className="lexical-attachment__file-name">
                {payload.filename || "Attachment"}
              </div>
              {Number.isFinite(payload.filesize) && (
                <div className="lexical-attachment__file-size">
                  {formatFileSize(payload.filesize)}
                </div>
              )}
            </div>
          </div>
        )}
        <figcaption>
          <input
            type="text"
            className="lexical-attachment__caption-input"
            value={payload.caption || ""}
            placeholder={isImage ? "Add caption" : "Describe attachment"}
            onChange={handleCaptionChange}
            onClick={(event) => event.stopPropagation()}
            onFocus={(event) => event.stopPropagation()}
          />
          {Number.isFinite(payload.filesize) && (
            <span className="lexical-attachment__caption-size">
              {formatFileSize(payload.filesize)}
            </span>
          )}
        </figcaption>
      </figure>
      {isImage && (
        <div
          className="lexical-attachment__resize-handle"
          onPointerDown={startResize}
          role="presentation"
        />
      )}
    </div>
  )
}
