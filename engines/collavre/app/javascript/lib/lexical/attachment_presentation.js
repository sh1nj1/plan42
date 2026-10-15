import { pptAttachmentProps } from "./ppt_attachment"
import { formatFileSize } from './attachment_payload'

// Shared by the editor decorator and sanitized, read-only descriptions.
export function attachmentLinkParts(filename, filesize) {
  const parts = [
    {className: 'attachment-link-icon', text: ''},
    {className: 'attachment-link-name', text: filename},
  ]
  const size = formatFileSize(filesize)
  if (size) parts.push({className: 'attachment-link-size', text: '', sizeLabel: size})
  return parts
}

export function attachmentLinkLabel(filename, filesize) {
  const size = formatFileSize(filesize)
  return size ? `${filename} (${size})` : filename
}

export function decorateAttachmentLinks(root) {
  root.querySelectorAll('a[download]').forEach(link => {
    // Preserve existing inline media previews rather than replacing them with a card.
    if (link.querySelector('img, video')) return
    const label = link.querySelector('.attachment-link-name') || link
    const filename = link.getAttribute('download') || label.textContent
    const preview = pptAttachmentProps(link.getAttribute('href'), filename)
    if (preview) {
      const frame = document.createElement('iframe')
      Object.assign(frame, preview)
      frame.setAttribute('allowfullscreen', '')
      link.replaceWith(frame)
      return
    }
    const parts = attachmentLinkParts(filename, link.getAttribute('data-filesize'))
    link.classList.add('attachment-link')
    link.setAttribute('aria-label', attachmentLinkLabel(filename, link.getAttribute('data-filesize')))
    link.replaceChildren(...parts.map(({className, text, sizeLabel}) => {
      const span = document.createElement('span')
      span.className = className
      span.textContent = text
      if (sizeLabel) span.dataset.filesizeLabel = sizeLabel
      return span
    }))
  })
}
