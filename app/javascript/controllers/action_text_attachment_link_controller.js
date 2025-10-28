import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  download(event) {
    const attachment = event.target.closest('action-text-attachment')
    if (!attachment) return

    const url = attachment.getAttribute('url')
    if (!url) return

    event.preventDefault()

    const filename = attachment.getAttribute('filename') || 'download'
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    link.style.display = 'none'
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
  }
}
