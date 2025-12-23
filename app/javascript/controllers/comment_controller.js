import { Controller } from "@hotwired/stimulus"
import { renderCommentMarkdown } from '../lib/utils/markdown'

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = [ "ownerButton", "reactionPicker", "reactionButton" ]

  connect() {
    const contentElement = this.element.querySelector('.comment-content')
    if (contentElement && contentElement.dataset.rendered !== 'true') {
      const text = contentElement.textContent || ''
      contentElement.innerHTML = renderCommentMarkdown(text)
      contentElement.dataset.rendered = 'true'
    }

    const currentUserId = document.body.dataset.currentUserId
    const commentAuthorId = this.element.dataset.userId

    if (currentUserId && commentAuthorId && currentUserId === commentAuthorId) {
      this.ownerButtonTargets.forEach((button) => {
        button.classList.remove('comment-owner-only')
      })
    }

    this.handleDocumentClick = this.handleDocumentClick.bind(this)
    document.addEventListener('click', this.handleDocumentClick)
  }

  disconnect() {
    document.removeEventListener('click', this.handleDocumentClick)
  }

  togglePicker(event) {
    event.preventDefault()
    event.stopPropagation()
    if (!this.hasReactionPickerTarget) return

    this.reactionPickerTarget.hidden = !this.reactionPickerTarget.hidden
  }

  selectReaction(event) {
    event.preventDefault()
    const emoji = event.currentTarget.dataset.emoji
    if (!emoji) return

    this.submitReaction(emoji, false)
    this.hideReactionPicker()
  }

  toggleReaction(event) {
    event.preventDefault()
    const button = event.currentTarget
    const emoji = button.dataset.emoji
    if (!emoji) return

    const reacted = button.dataset.reacted === 'true'
    this.submitReaction(emoji, reacted)
  }

  hideReactionPicker() {
    if (!this.hasReactionPickerTarget) return
    this.reactionPickerTarget.hidden = true
  }

  handleDocumentClick(event) {
    if (!this.hasReactionPickerTarget || this.reactionPickerTarget.hidden) return
    if (this.reactionPickerTarget.contains(event.target) || this.reactionButtonTarget?.contains(event.target)) return

    this.hideReactionPicker()
  }

  async submitReaction(emoji, reacted) {
    const creativeId = this.element.dataset.creativeId
    const commentId = this.element.dataset.commentId
    if (!creativeId || !commentId) return

    const url = new URL(`/creatives/${creativeId}/comments/${commentId}/reactions`, window.location.origin)
    const method = reacted ? 'DELETE' : 'POST'
    const headers = {
      'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content || '',
      'Accept': 'text/html'
    }
    const options = { method, headers }

    if (method === 'POST') {
      options.headers['Content-Type'] = 'application/json'
      options.body = JSON.stringify({ emoji })
    } else {
      url.searchParams.set('emoji', emoji)
    }

    try {
      const response = await fetch(url.toString(), options)
      if (!response.ok) {
        throw new Error('Failed to update reaction')
      }

      const html = await response.text()
      const doc = new DOMParser().parseFromString(html, 'text/html')
      const nextElement = doc.body.firstElementChild
      if (nextElement) {
        this.element.replaceWith(nextElement)
      }
    } catch (error) {
      alert(error?.message || 'Failed to update reaction')
    }
  }
}
