const DEFAULT_STATUS = "ready"

function coerceNumber(value) {
  if (value === null || value === undefined) return null
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return null
  return parsed
}

export function parseDimension(value) {
  if (value === null || value === undefined) return null
  if (typeof value === "number" && Number.isFinite(value)) return value
  const match = String(value).trim().match(/([0-9]+(?:\.[0-9]+)?)/)
  if (!match) return null
  const parsed = parseFloat(match[1])
  return Number.isFinite(parsed) ? parsed : null
}

export function formatFileSize(bytes) {
  const value = coerceNumber(bytes)
  if (!Number.isFinite(value) || value <= 0) return ""
  const units = ["B", "KB", "MB", "GB", "TB"]
  let size = value
  let unitIndex = 0
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024
    unitIndex += 1
  }
  return `${size % 1 === 0 ? size : size.toFixed(1)} ${units[unitIndex]}`
}

export function normalizeAttachmentCaption(rawCaption, {filename, filesize}) {
  if (!rawCaption) return ""
  const normalized = rawCaption.replace(/•/g, " ").replace(/\s+/g, " ").trim()
  if (!normalized) return ""
  const defaults = new Set()
  if (filename) {
    defaults.add(filename.toLowerCase())
  }
  if (filename && Number.isFinite(filesize)) {
    defaults.add(`${filename} ${formatFileSize(filesize)}`.toLowerCase())
  }
  return defaults.has(normalized.toLowerCase()) ? "" : normalized
}

export function sanitizeAttachmentPayload(raw = {}) {
  const sanitized = {
    sgid: raw.sgid || null,
    url: raw.url || null,
    filename: (raw.filename || "").trim(),
    contentType: raw.contentType || raw["content-type"] || null,
    filesize: coerceNumber(raw.filesize),
    caption: raw.caption || "",
    previewable: Boolean(raw.previewable),
    width: parseDimension(raw.width ?? raw.dataWidth ?? raw["data-width"]),
    height: parseDimension(raw.height ?? raw.dataHeight ?? raw["data-height"]),
    status: raw.status || DEFAULT_STATUS,
    progress: Number.isFinite(raw.progress) ? raw.progress : raw.status === "ready" ? 100 : 0,
    localUrl: raw.localUrl || null,
    error: raw.error || null
  }

  sanitized.caption = normalizeAttachmentCaption((raw.caption || "").trim(), sanitized)

  return sanitized
}

export function attachmentPayloadFromAttachmentElement(element) {
  if (!(element instanceof Element)) return null
  const payload = sanitizeAttachmentPayload({
    sgid: element.getAttribute("sgid"),
    url: element.getAttribute("url"),
    filename: element.getAttribute("filename"),
    contentType: element.getAttribute("content-type"),
    filesize: element.getAttribute("filesize"),
    caption: element.getAttribute("caption"),
    previewable: element.getAttribute("previewable") === "true",
    width: element.getAttribute("data-width"),
    height: element.getAttribute("data-height")
  })
  return payload
}

export function attachmentPayloadFromFigure(figure) {
  if (!(figure instanceof Element)) return null
  if (!figure.classList.contains("attachment")) return null
  let data = null
  const dataset = figure.getAttribute("data-trix-attachment")
  if (dataset) {
    try {
      data = JSON.parse(dataset)
    } catch (_error) {
      data = null
    }
  }

  const payload = sanitizeAttachmentPayload({
    sgid: data?.sgid || data?.attachable_sgid || null,
    url: data?.url || data?.href || null,
    filename: data?.filename || data?.name || figure.querySelector(".attachment__name")?.textContent || "",
    contentType: data?.contentType || data?.content_type || figure.getAttribute("data-trix-content-type"),
    filesize: data?.filesize ?? data?.file_size ?? data?.size ?? null,
    previewable: data?.previewable ?? figure.classList.contains("attachment--preview"),
    width: data?.width ?? data?.presentation?.width ?? figure.getAttribute("data-width"),
    height: data?.height ?? data?.presentation?.height ?? figure.getAttribute("data-height"),
    caption: data?.caption || figure.querySelector("figcaption")?.textContent || ""
  })

  if (!payload.url) {
    const img = figure.querySelector("img")
    if (img) {
      payload.url = img.getAttribute("src") || null
      payload.previewable = true
      payload.width = payload.width || parseDimension(img.getAttribute("data-width") || img.getAttribute("width") || img.style.width)
      payload.height = payload.height || parseDimension(img.getAttribute("data-height") || img.getAttribute("height") || img.style.height)
      if (!payload.caption) {
        payload.caption = normalizeAttachmentCaption(img.getAttribute("alt"), payload)
      }
    }
  }

  return payload
}

function buildDataTrixAttachment(payload) {
  return JSON.stringify({
    sgid: payload.sgid,
    contentType: payload.contentType,
    filename: payload.filename,
    name: payload.filename,
    filesize: payload.filesize,
    size: payload.filesize,
    url: payload.url,
    href: payload.url,
    previewable: payload.previewable,
    caption: payload.caption,
    presentation: {
      width: payload.width || undefined,
      height: payload.height || undefined
    }
  })
}

export function attachmentPayloadToHTMLElement(payload) {
  const sanitized = sanitizeAttachmentPayload(payload)
  const element = document.createElement("action-text-attachment")
  if (sanitized.sgid) element.setAttribute("sgid", sanitized.sgid)
  if (sanitized.contentType) element.setAttribute("content-type", sanitized.contentType)
  if (sanitized.url) element.setAttribute("url", sanitized.url)
  if (sanitized.filename) element.setAttribute("filename", sanitized.filename)
  if (Number.isFinite(sanitized.filesize)) element.setAttribute("filesize", String(sanitized.filesize))
  if (sanitized.caption) element.setAttribute("caption", sanitized.caption)
  if (sanitized.previewable) element.setAttribute("previewable", "true")
  if (Number.isFinite(sanitized.width)) element.setAttribute("data-width", String(Math.round(sanitized.width)))
  if (Number.isFinite(sanitized.height)) element.setAttribute("data-height", String(Math.round(sanitized.height)))

  const figure = document.createElement("figure")
  figure.className = `attachment ${sanitized.previewable ? "attachment--preview" : "attachment--file"}`
  if (sanitized.contentType) {
    figure.classList.add(`attachment--${sanitized.contentType.split("/")[1] || sanitized.contentType}`)
    figure.setAttribute("data-trix-content-type", sanitized.contentType)
  }
  figure.setAttribute("data-trix-attachment", buildDataTrixAttachment(sanitized))

  if (sanitized.previewable && sanitized.url) {
    const img = document.createElement("img")
    img.src = sanitized.url
    img.alt = sanitized.caption || sanitized.filename || ""
    if (Number.isFinite(sanitized.width)) {
      img.setAttribute("data-width", String(Math.round(sanitized.width)))
      img.style.width = `${Math.round(sanitized.width)}px`
    }
    if (Number.isFinite(sanitized.height)) {
      img.setAttribute("data-height", String(Math.round(sanitized.height)))
      img.style.height = `${Math.round(sanitized.height)}px`
    }
    figure.appendChild(img)
  } else {
    const wrapper = document.createElement("div")
    wrapper.className = "attachment__file"

    const link = document.createElement("a")
    link.href = sanitized.url || "#"
    link.className = "attachment__download"
    if (sanitized.filename) link.setAttribute("download", sanitized.filename)
    link.textContent = sanitized.filename || "Attachment"
    wrapper.appendChild(link)

    const info = document.createElement("div")
    info.className = "attachment__file-info"
    const nameSpan = document.createElement("span")
    nameSpan.className = "attachment__name"
    nameSpan.textContent = sanitized.filename || "Attachment"
    info.appendChild(nameSpan)
    if (Number.isFinite(sanitized.filesize)) {
      const sizeSpan = document.createElement("span")
      sizeSpan.className = "attachment__size"
      sizeSpan.textContent = formatFileSize(sanitized.filesize)
      info.appendChild(sizeSpan)
    }
    wrapper.appendChild(info)
    figure.appendChild(wrapper)
  }

  const figcaption = document.createElement("figcaption")
  figcaption.className = "attachment__caption"
  const captionName = document.createElement("span")
  captionName.className = "attachment__name"
  captionName.textContent = sanitized.caption || sanitized.filename || "Attachment"
  figcaption.appendChild(captionName)
  if (Number.isFinite(sanitized.filesize)) {
    const captionSize = document.createElement("span")
    captionSize.className = "attachment__size"
    captionSize.textContent = formatFileSize(sanitized.filesize)
    figcaption.appendChild(captionSize)
  }
  figure.appendChild(figcaption)

  element.appendChild(figure)
  return {element, payload: sanitized}
}

export function ensureSgid(payload) {
  if (payload.sgid) return payload
  const id = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2)
  return {...payload, sgid: `temp-${id}`}
}
