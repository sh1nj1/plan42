import { Controller } from "@hotwired/stimulus"
import { renderMarkdown, renderMarkdownInline } from '../lib/utils/markdown'

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = [ "ownerButton" ]

  connect() {
    const contentElement = this.element.querySelector('.comment-content')
    if (contentElement && contentElement.dataset.rendered !== 'true') {
      const text = contentElement.textContent || ''
      const html = text.includes('\n') ? renderMarkdown(text).trim() : renderMarkdownInline(text).trim()
      contentElement.innerHTML = html
      contentElement.dataset.rendered = 'true'
    }

    const currentUserId = document.body.dataset.currentUserId
    const commentAuthorId = this.element.dataset.userId

    if (currentUserId && commentAuthorId && currentUserId === commentAuthorId) {
      this.ownerButtonTargets.forEach((button) => {
        button.classList.remove('comment-owner-only')
      })
    }
  }
}
