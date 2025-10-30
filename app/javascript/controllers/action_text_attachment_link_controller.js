import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  download(event) {
    const attachment = event.target.closest('action-text-attachment, figure.attachment')
    if (!attachment) return

    const metadata = this.parseMetadata(attachment)

    let url = attachment.getAttribute('url') || attachment.dataset?.url || metadata?.url || metadata?.href
    let filename =
      attachment.getAttribute('filename') ||
      attachment.dataset?.filename ||
      metadata?.filename ||
      metadata?.name

    const anchor = attachment.querySelector('a[download]') || attachment.querySelector('a[href]')
    const image = attachment.querySelector('img[src]')

    if (!url && anchor) url = anchor.href
    if (!url && image) url = image.src
    if (!url) return

    if (!filename && anchor) filename = anchor.getAttribute('download') || anchor.textContent?.trim()
    if (!filename && image) filename = image.getAttribute('alt')

    if (!filename) {
      const captionName = attachment.querySelector('.attachment__name')
      if (captionName) filename = captionName.textContent?.trim()
    }

    if (!filename) filename = 'download'

    event.preventDefault()

    const link = document.createElement('a')
    link.href = url
    link.download = filename
    link.style.display = 'none'
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
  }

  parseMetadata(attachment) {
    const sources = [attachment.dataset?.trixAttachment, attachment.dataset?.trixAttributes]

    for (const source of sources) {
      if (!source) continue

      try {
        const data = JSON.parse(source)
        if (data && typeof data === 'object') return data
      } catch (error) {
        // Ignore parse errors and continue to the next source
      }
    }

    return null
  }
}
