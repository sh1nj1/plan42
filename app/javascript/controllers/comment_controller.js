import { Controller } from "@hotwired/stimulus"
import { renderCommentMarkdown } from '../lib/utils/markdown'

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = ["ownerButton", "reactionPicker", "reactionButton"]

  connect() {
    const contentElement = this.element.querySelector('.comment-content')
    if (contentElement && contentElement.dataset.rendered !== 'true') {
      const text = contentElement.textContent || ''
      contentElement.innerHTML = renderCommentMarkdown(text)
      contentElement.dataset.rendered = 'true'
    }

    this.currentUserId = document.body.dataset.currentUserId
    const commentAuthorId = this.element.dataset.userId

    if (this.currentUserId && commentAuthorId && this.currentUserId === commentAuthorId) {
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
      'Accept': 'application/json'
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

      const data = await response.json()
      this.updateReactionsUI(data)
    } catch (error) {
      alert(error?.message || 'Failed to update reaction')
    }
  }

  updateReactionsUI(reactionsData) {
    // reactionsData: [{ emoji, count, user_ids: [] }, ...]
    const reactionsContainer = this.element.querySelector('.comment-reactions')
    if (!reactionsContainer) return

    // Find the "Add" button to preserve it
    const addButton = reactionsContainer.querySelector('.comment-reaction-add')

    // Clear existing reaction buttons only (exclude adder)
    // It's safer to clear everything except the add button, then re-append.

    // 1. Remove all .comment-reaction elements
    reactionsContainer.querySelectorAll('.comment-reaction').forEach(el => el.remove())

    // 2. Insert new buttons before the addButton
    reactionsData.forEach(reaction => {
      const { emoji, count, user_ids } = reaction

      const button = document.createElement('button')
      button.className = 'comment-reaction'
      button.type = 'button'
      button.dataset.action = 'click->comment#toggleReaction'
      button.dataset.emoji = emoji

      const reacted = this.currentUserId && user_ids.map(String).includes(String(this.currentUserId))
      if (reacted) {
        button.classList.add('reacted')
        button.dataset.reacted = 'true'
      } else {
        button.dataset.reacted = 'false'
      }

      const emojiSpan = document.createElement('span')
      emojiSpan.textContent = emoji
      button.appendChild(emojiSpan)

      if (count > 1) {
        const countSpan = document.createElement('span')
        countSpan.className = 'comment-reaction-count'
        countSpan.textContent = count
        button.appendChild(countSpan)
      }

      if (addButton) {
        reactionsContainer.insertBefore(button, addButton)
      } else {
        reactionsContainer.appendChild(button)
      }
    })
  }
}
