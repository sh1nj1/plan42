import { Controller } from "@hotwired/stimulus"
import { renderCommentMarkdown } from '../lib/utils/markdown'
import CommonPopup from '../lib/common_popup'

// Connects to data-controller="comment"
export default class extends Controller {
  static targets = ["ownerButton", "deleteButton", "approveButton", "actionApproveControls", "reviewButton", "replaceButton"]

  connect() {
    const contentElement = this.element.querySelector('.comment-content')
    if (contentElement && contentElement.dataset.rendered !== 'true') {
      const text = contentElement.textContent || ''
      contentElement.innerHTML = renderCommentMarkdown(text)
      contentElement.dataset.rendered = 'true'
    }

    // Text selection quote support
    this.handleMouseUp = this.handleMouseUp.bind(this)
    this.element.addEventListener('mouseup', this.handleMouseUp)

    // Bound handlers for review/replace buttons (stored for cleanup)
    this._boundReviewClick = this._onReviewClick.bind(this)
    this._boundReplaceClick = this._onReplaceClick.bind(this)

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
    this.element.removeEventListener('mouseup', this.handleMouseUp)
    this._removeSelectionChangeListener()
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
          formController.quoteComment(commentId, selectedText)
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

  reviewButtonTargetConnected(button) {
    button.addEventListener('click', this._boundReviewClick)
  }

  reviewButtonTargetDisconnected(button) {
    button.removeEventListener('click', this._boundReviewClick)
  }

  replaceButtonTargetConnected(button) {
    button.addEventListener('click', this._boundReplaceClick)
    // Only listen for selectionchange when a replace button exists
    this._addSelectionChangeListener()
  }

  replaceButtonTargetDisconnected(button) {
    button.removeEventListener('click', this._boundReplaceClick)
    if (!this.hasReplaceButtonTarget) {
      this._removeSelectionChangeListener()
    }
  }

  _onReviewClick(event) {
    event.preventDefault()
    event.stopPropagation()
    const commentId = this.element.dataset.commentId
    const contentEl = this.element.querySelector('.comment-content')
    const fullText = contentEl ? contentEl.textContent.trim() : ''
    const formController = this.findFormController()
    if (formController && fullText) {
      formController.quoteComment(commentId, fullText)
    }
  }

  _onReplaceClick(event) {
    event.preventDefault()
    event.stopPropagation()
    const selectedText = this._getSelectedTextInContent()
    if (!selectedText) return

    const commentId = this.element.dataset.commentId
    const formController = this.findFormController()
    if (formController) {
      formController.quoteComment(commentId, selectedText)
    }
    window.getSelection().removeAllRanges()
    this._updateReplaceButton()
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

  _addSelectionChangeListener() {
    if (this._selectionChangeActive) return
    this._handleSelectionChange = this._handleSelectionChange.bind(this)
    document.addEventListener('selectionchange', this._handleSelectionChange)
    this._selectionChangeActive = true
  }

  _removeSelectionChangeListener() {
    if (!this._selectionChangeActive) return
    document.removeEventListener('selectionchange', this._handleSelectionChange)
    this._selectionChangeActive = false
  }

  _handleSelectionChange() {
    this._updateReplaceButton()
  }

  _updateReplaceButton() {
    if (!this.hasReplaceButtonTarget) return
    const hasSelection = !!this._getSelectedTextInContent()
    this.replaceButtonTargets.forEach((btn) => {
      btn.disabled = !hasSelection
    })
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
