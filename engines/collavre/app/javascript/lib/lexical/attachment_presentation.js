import { formatFileSize } from './attachment_payload'

// Shared by the editor decorator and sanitized, read-only descriptions.
export function attachmentLinkParts(filename, filesize) {
  const parts = [
    {className: 'attachment-link-icon', text: '📎'},
    {className: 'attachment-link-name', text: filename},
  ]
  const size = formatFileSize(filesize)
  if (size) parts.push({className: 'attachment-link-size', text: `(${size})`})
  return parts
}

export function decorateAttachmentLinks(root) {
  root.querySelectorAll('a[download]').forEach(link => {
    // Preserve existing inline media previews rather than replacing them with a card.
    if (link.querySelector('img, video')) return
    const label = link.querySelector('.attachment-link-name') || link
    const filename = link.getAttribute('download') || label.textContent
    const parts = attachmentLinkParts(filename, link.getAttribute('data-filesize'))
    link.classList.add('attachment-link')
    link.replaceChildren(...parts.map(({className, text}) => {
      const span = document.createElement('span')
      span.className = className
      span.textContent = text
      return span
    }))
  })
}
