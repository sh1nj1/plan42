import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = [ "ownerButton" ]

  connect() {
    // Render Markdown
    if (window.marked) {
      const contentElement = this.element.querySelector('.comment-content');
      if (contentElement && contentElement.dataset.rendered !== 'true') {
        const text = contentElement.textContent;
        const html = text.includes('\n') ? window.marked.parse(text).trim() : window.marked.parseInline(text).trim();
        contentElement.innerHTML = html;
        contentElement.dataset.rendered = 'true';
      }
    }

    // Show actions for the comment owner
    const currentUserId = document.body.dataset.currentUserId;
    const commentAuthorId = this.element.dataset.userId;

    if (currentUserId && commentAuthorId && currentUserId === commentAuthorId) {
      this.ownerButtonTargets.forEach((button) => {
        button.classList.remove('comment-owner-only')
      })
    }
  }
}
