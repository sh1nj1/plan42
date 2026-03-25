import { Controller } from "@hotwired/stimulus"
import { renderCommentMarkdown } from '../lib/utils/markdown'
import CommonPopup from '../lib/common_popup'

// Global tracker: persists streaming state across Turbo replacements
// (each replacement creates a new controller instance, losing instance state)
if (!window._streamingCommentIds) window._streamingCommentIds = new Set()

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = ["ownerButton", "deleteButton", "approveButton", "actionApproveControls"]

  get _commentId() {
    return this.element.dataset.commentId
  }

  get _isStreaming() {
    return window._streamingCommentIds.has(this._commentId)
  }

  set _isStreaming(val) {
    if (val) {
      window._streamingCommentIds.add(this._commentId)
    } else {
      window._streamingCommentIds.delete(this._commentId)
    }
  }

  // --- Streaming state helpers ---

  get _isAiComment() {
    return this.element.dataset.aiUser === 'true'
  }

  // Server explicitly marked this broadcast as streaming (true) or done (false).
  // When no streaming local is provided the partial defaults to "false".
  get _serverStreaming() {
    return this.element.dataset.streaming === 'true'
  }

  // The server sent streaming: false explicitly — stream just ended.
  get _serverStreamingDone() {
    return this.element.dataset.streaming === 'false'
  }

  // Should we treat this comment as currently streaming?
  // True when the server says so OR the global Set remembers it,
  // but NOT if the server explicitly signalled completion.
  _shouldStream(text) {
    if (!this._isAiComment || !text.trim()) return false
    if (this._serverStreamingDone) return false
    return this._isStreaming || this._serverStreaming
  }

  _appendStreamingCursor(el) {
    const cursor = document.createElement('span')
    cursor.className = 'streaming-cursor'
    cursor.textContent = '▍'
    let target = el
    while (target.lastElementChild && target.lastElementChild.tagName !== 'BR') {
      target = target.lastElementChild
    }
    target.appendChild(cursor)
  }

  _resetStreamingTimeout() {
    if (this._streamingTimeout) clearTimeout(this._streamingTimeout)
    this._streamingTimeout = setTimeout(() => {
      const currentEl = this.element?.querySelector('.comment-content')
      if (currentEl) {
        currentEl.dataset.rendering = 'true'
        try {
          currentEl.classList.remove('streaming')
          const c = currentEl.querySelector('.streaming-cursor')
          if (c) c.remove()
        } finally {
          requestAnimationFrame(() => { currentEl.dataset.rendering = 'false' })
        }
      }
      this._isStreaming = false
    }, 10000)
  }

  _cleanupStreaming() {
    this._isStreaming = false
    if (this._streamingTimeout) {
      clearTimeout(this._streamingTimeout)
      this._streamingTimeout = null
    }
  }

  connect() {
    if (!this._streamingTimeout) this._streamingTimeout = null
    const contentElement = this.element.querySelector('.comment-content')
    if (contentElement && contentElement.dataset.rendered !== 'true') {
      contentElement.dataset.rendering = 'true'
      try {
        const text = contentElement.textContent || ''
        if (this._isAiComment && text.trim() === '...') {
          // Streaming placeholder — show animated dots
          this._isStreaming = true
          contentElement.innerHTML = '<span class="streaming-dots"><span>.</span><span>.</span><span>.</span></span>'
          contentElement.classList.add('streaming')
        } else if (this._shouldStream(text)) {
          // Streaming content arrived — render markdown with cursor
          this._isStreaming = true
          contentElement.innerHTML = renderCommentMarkdown(text)
          this._appendStreamingCursor(contentElement)
          contentElement.classList.add('streaming')
          this._resetStreamingTimeout()
        } else {
          contentElement.innerHTML = renderCommentMarkdown(text)
          contentElement.classList.remove('streaming')
          if (this._isStreaming) this._cleanupStreaming()
        }
        contentElement.dataset.rendered = 'true'
      } finally {
        requestAnimationFrame(() => { contentElement.dataset.rendering = 'false' })
      }
    }

    // Text selection quote support
    this.handleMouseUp = this.handleMouseUp.bind(this)
    this.element.addEventListener('mouseup', this.handleMouseUp)

    this.currentUserId = document.body.dataset.currentUserId
    const commentAuthorId = this.element.dataset.userId
    const creativeOwnerId = this.element.dataset.creativeOwnerId
    const isAdmin = document.body.dataset.systemAdmin === 'true'
    const isOwner = this.currentUserId && commentAuthorId && this.currentUserId === commentAuthorId
    const isCreativeOwner = this.currentUserId && creativeOwnerId && this.currentUserId === creativeOwnerId

    if (isOwner) {
      this.ownerButtonTargets.forEach((button) => {
        button.classList.remove('comment-owner-only')
      })
    }

    // Show delete button if user is comment author, creative owner, or admin
    if (isOwner || isCreativeOwner || isAdmin) {
      this.deleteButtonTargets.forEach((button) => {
        button.classList.remove('comment-delete-hidden')
      })
    }

    // Show approve button: user must be the designated approver or a system admin
    const hasPendingAction = this.element.dataset.hasPendingAction === 'true'
    const approverId = this.element.dataset.approverId
    const isApprover = this.currentUserId && approverId && this.currentUserId === approverId
    const canApprove = hasPendingAction && (isApprover || isAdmin)

    if (canApprove) {
      this.approveButtonTargets.forEach((button) => {
        button.classList.remove('comment-approve-hidden')
      })
      // Also show action block approve controls (edit action button, form)
      this.actionApproveControlsTargets.forEach((el) => {
        el.classList.remove('comment-approve-hidden')
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

  disconnect() {
    if (this._streamingTimeout) {
      clearTimeout(this._streamingTimeout)
      this._streamingTimeout = null
    }
    this.element.removeEventListener('mouseup', this.handleMouseUp)
    this.hideReviewPopup()
    if (this._reviewPopupEl) {
      this._reviewPopupEl.remove()
      this._reviewPopupEl = null
      this._reviewPopup = null
    }
  }

  handleMouseUp() {
    // Small delay to let selection finalize
    requestAnimationFrame(() => {
      this.hideReviewPopup()

      const selection = window.getSelection()
      if (!selection || selection.isCollapsed) return

      const selectedText = selection.toString().trim()
      if (!selectedText) return

      // Ensure selection is within this comment's content
      const contentEl = this.element.querySelector('.comment-content')
      if (!contentEl) return

      const range = selection.getRangeAt(0)
      if (!contentEl.contains(range.commonAncestorContainer)) return

      // Show review popup below the selection using CommonPopup
      const rect = range.getBoundingClientRect()
      this.showReviewPopup(rect, selectedText)
    })
  }

  showReviewPopup(anchorRect, selectedText) {
    // Create or reuse popup element
    if (!this._reviewPopupEl) {
      const el = document.createElement('div')
      el.className = 'common-popup comment-review-popup'
      el.style.display = 'none'
      el.style.padding = '0.3em'

      const list = document.createElement('ul')
      list.style.listStyle = 'none'
      list.style.margin = '0'
      list.style.padding = '0'
      el.appendChild(list)

      const commentsPopup = this.element.closest('#comments-popup')
      if (commentsPopup) {
        commentsPopup.appendChild(el)
      } else {
        document.body.appendChild(el)
      }
      this._reviewPopupEl = el
    }

    const reviewLabel = this.element.closest('#comments-popup')?.dataset?.reviewButtonText || 'Review'

    this._reviewPopup = new CommonPopup(this._reviewPopupEl, {
      onSelect: () => {
        const commentId = this.element.dataset.commentId
        const formController = this.findFormController()
        if (formController) {
          formController.appendReviewQuote(commentId, selectedText)
        }
        window.getSelection().removeAllRanges()
        this.hideReviewPopup()
      },
      renderItem: () => reviewLabel,
    })

    // Position below the selection end
    const belowRect = {
      left: anchorRect.left,
      right: anchorRect.right,
      top: anchorRect.bottom,
      bottom: anchorRect.bottom + 4,
      width: anchorRect.width,
    }

    this._reviewPopup.setItems([{ label: reviewLabel }])
    this._reviewPopup.showAt(belowRect)
  }

  hideReviewPopup() {
    if (this._reviewPopup) {
      this._reviewPopup.hide()
    }
  }

  findFormController() {
    const popup = this.element.closest('#comments-popup')
    if (!popup) return null
    return this.application.getControllerForElementAndIdentifier(popup, 'comments--form')
  }

  // Stimulus action: click->comment#reviewClick (bound via data-action in template)
  reviewClick(event) {
    event.preventDefault()
    const selectedText = this._getSelectedTextInContent()
    if (!selectedText) {
      this._showReviewHint(event.currentTarget)
      return
    }
    const commentId = this.element.dataset.commentId
    const formController = this.findFormController()
    if (formController) {
      formController.appendReviewQuote(commentId, selectedText)
      const textarea = formController.textareaTarget
      if (textarea) {
        textarea.scrollIntoView({ behavior: 'smooth', block: 'center' })
        textarea.focus()
        textarea.selectionStart = textarea.selectionEnd = textarea.value.length
      }
    }
    window.getSelection().removeAllRanges()
  }

  _showReviewHint(button) {
    // Remove any existing hint
    document.querySelectorAll('.review-hint').forEach(el => el.remove())

    // Show hint popup near the button using fixed positioning
    const rect = button.getBoundingClientRect()
    const hint = document.createElement('div')
    hint.className = 'review-hint'
    hint.textContent = button.dataset.hintText || 'Select text to review'
    hint.style.position = 'fixed'
    hint.style.top = `${rect.top - 8}px`
    hint.style.left = `${rect.left + rect.width / 2}px`
    hint.style.transform = 'translate(-50%, -100%)'
    document.body.appendChild(hint)
    hint.addEventListener('animationend', () => hint.remove(), { once: true })
  }

  _getSelectedTextInContent() {
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed) return null

    const text = selection.toString().trim()
    if (!text) return null

    const contentEl = this.element.querySelector('.comment-content')
    if (!contentEl) return null

    const range = selection.getRangeAt(0)
    if (!contentEl.contains(range.commonAncestorContainer)) return null

    return text
  }

  // Selection change listener and replace button logic removed — unified into review

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

  async restoreSnapshot(event) {
    const button = event.currentTarget
    const snapshotId = button.dataset.snapshotId
    const creativeId = button.dataset.creativeId
    const confirmText = button.dataset.confirmText || 'Restore original messages?'

    if (!confirm(confirmText)) return

    button.disabled = true
    try {
      const response = await fetch(`/creatives/${creativeId}/comments/snapshots/${snapshotId}/restore`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content,
          'Content-Type': 'application/json',
        },
      })
      if (response.ok) {
        // Restored comments will appear via ActionCable broadcast;
        // the summary comment (this one) will be destroyed via broadcast too
      } else {
        const data = await response.json().catch(() => ({}))
        alert(data.error || 'Failed to restore')
        button.disabled = false
      }
    } catch (error) {
      console.error('Error restoring snapshot:', error)
      alert('Failed to restore')
      button.disabled = false
    }
  }
}
