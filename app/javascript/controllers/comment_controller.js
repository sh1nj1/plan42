import { Controller } from "@hotwired/stimulus"
import { renderCommentMarkdown } from '../lib/utils/markdown'

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = ["ownerButton"]

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
  }

  triggerReactionPicker(event) {
    event.preventDefault()
    event.stopPropagation()

    // Dispatch event for global picker
    const customEvent = new CustomEvent('reaction-picker:open', {
      detail: {
        controller: this,
        target: event.currentTarget
      },
      bubbles: true
    })
    window.dispatchEvent(customEvent)
  }

  toggleReaction(event) {
    event.preventDefault()
    const button = event.currentTarget
    const emoji = button.dataset.emoji
    if (!emoji) return

    const reacted = button.dataset.reacted === 'true'
    this.submitReaction(emoji, reacted)
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
    let reactionsContainer = this.element.querySelector('.comment-reactions')

    // 1. If no reactions, remove container and return
    if (!reactionsData || reactionsData.length === 0) {
      if (reactionsContainer) {
        reactionsContainer.remove()
      }
      return
    }

    // 2. If reactions exist but container doesn't, create it
    let reactionsList
    if (!reactionsContainer) {
      reactionsContainer = document.createElement('div')
      reactionsContainer.className = 'comment-reactions'

      reactionsList = document.createElement('div')
      reactionsList.className = 'comment-reaction-list'
      reactionsContainer.appendChild(reactionsList)

      // Insert after attachments if present, otherwise after content
      const attachmentsElement = this.element.querySelector('.comment-attachments')
      const contentElement = this.element.querySelector('.comment-content')

      if (attachmentsElement) {
        attachmentsElement.insertAdjacentElement('afterend', reactionsContainer)
      } else if (contentElement) {
        contentElement.insertAdjacentElement('afterend', reactionsContainer)
      } else {
        this.element.appendChild(reactionsContainer)
      }
    } else {
      reactionsList = reactionsContainer.querySelector('.comment-reaction-list')
      if (!reactionsList) {
        reactionsList = document.createElement('div')
        reactionsList.className = 'comment-reaction-list'
        reactionsContainer.appendChild(reactionsList)
      }
    }

    // 3. Clear existing list (Add button is elsewhere now, safe to clear)
    reactionsList.innerHTML = ''

    // 4. Append new reaction buttons
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
      emojiSpan.className = 'comment-reaction-emoji'
      emojiSpan.textContent = emoji
      button.appendChild(emojiSpan)

      const countSpan = document.createElement('span')
      countSpan.className = 'comment-reaction-count'
      if (count > 1) {
        countSpan.classList.add('is-visible')
      }
      countSpan.textContent = count
      button.appendChild(countSpan)

      reactionsList.appendChild(button)
    })
  }
}
