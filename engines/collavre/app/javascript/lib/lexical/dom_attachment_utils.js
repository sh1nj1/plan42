import {
  sanitizeAttachmentPayload,
  attachmentPayloadFromAttachmentElement,
  attachmentPayloadFromFigure,
  attachmentPayloadToHTMLElement
} from "./attachment_payload"

export function extractAttachmentPayloadFromDOM(element) {
  if (!(element instanceof Element)) return null
  if (element.tagName === "ACTION-TEXT-ATTACHMENT") {
    return attachmentPayloadFromAttachmentElement(element)
  }
  if (element.tagName === "FIGURE") {
    return attachmentPayloadFromFigure(element)
  }
  return null
}

export function ensureAttachmentWrapper(element) {
  if (!(element instanceof Element)) return null
  const payload = attachmentPayloadFromAttachmentElement(element)
  if (payload) return {element, payload}

  const figure = element.tagName === "FIGURE" ? element : element.querySelector("figure.attachment")
  if (!figure) return null
  const figurePayload = attachmentPayloadFromFigure(figure)
  if (!figurePayload) return null
  const {element: wrapper, payload: sanitized} = attachmentPayloadToHTMLElement(figurePayload)
  figure.replaceWith(wrapper)
  return {element: wrapper, payload: sanitized}
}

export function serializeAttachmentPayloadToHTML(payload) {
  const {element} = attachmentPayloadToHTMLElement(payload)
  return element.outerHTML
}

export function normalizeAttachmentPair(container) {
  if (!(container instanceof Element)) return
  const attachments = Array.from(container.querySelectorAll("action-text-attachment"))
  const seen = new Set()

  attachments.forEach((attachment) => {
    const payload = attachmentPayloadFromAttachmentElement(attachment)
    if (!payload) return
    const key = `${payload.sgid || payload.filename}-${payload.url || ""}`
    if (seen.has(key)) {
      attachment.remove()
      return
    }
    seen.add(key)

    const figure = attachment.querySelector("figure.attachment")
    if (figure) {
      attachmentPayloadToHTMLElement(payload) // ensures figure JSON is in-sync
    }
  })

  container.querySelectorAll("figure.attachment").forEach((figure) => {
    if (figure.closest("action-text-attachment")) return
    const payload = attachmentPayloadFromFigure(figure)
    if (!payload) return
    const {element} = attachmentPayloadToHTMLElement(payload)
    figure.replaceWith(element)
  })
}
