import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  download(event) {
    const attachment = event.target.closest('action-text-attachment')
    if (!attachment) return

    let url = attachment.getAttribute('url')
    let filename = attachment.getAttribute('filename')

    const anchor = attachment.querySelector('a[download]') || attachment.querySelector('a[href]')
    const image = attachment.querySelector('img[src]')

    if (!url && anchor) url = anchor.href
    if (!url && image) url = image.src
    if (!url) return

    if (!filename && anchor) filename = anchor.getAttribute('download') || anchor.textContent?.trim()
    if (!filename && image) filename = image.getAttribute('alt')
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
}
