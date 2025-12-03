import { Controller } from '@hotwired/stimulus'
import { copyTextToClipboard } from '../../utils/clipboard'
import { renderMarkdownInContainer } from '../../lib/utils/markdown'
import { openLinkSelection } from '../../lib/link_selection_popup'

const COMMENTS_PER_PAGE = 10

export default class extends Controller {
  static targets = ['list']

  connect() {
    this.selection = new Set()
    this.currentPage = 1
    this.loadingMore = false
    this.allLoaded = false
    this.movingComments = false
    this.stickToBottom = true
    this.manualSearchQuery = null

    this.handleScroll = this.handleScroll.bind(this)
    this.handleChange = this.handleChange.bind(this)
    this.handleClick = this.handleClick.bind(this)
    this.handleSubmit = this.handleSubmit.bind(this)

    this.listTarget.addEventListener('scroll', this.handleScroll)
    this.listTarget.addEventListener('change', this.handleChange)
    this.listTarget.addEventListener('click', this.handleClick)
    this.listTarget.addEventListener('submit', this.handleSubmit)

    this.observeListMutations()
  }

  disconnect() {
    this.listTarget.removeEventListener('scroll', this.handleScroll)
    this.listTarget.removeEventListener('change', this.handleChange)
    this.listTarget.removeEventListener('click', this.handleClick)
    this.listTarget.removeEventListener('submit', this.handleSubmit)
    if (this.listObserver) {
      this.listObserver.disconnect()
      this.listObserver = null
    }
  }

  get popupController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--popup')
  }

  get formController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--form')
  }

  get presenceController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--presence')
  }

  onPopupOpened({ creativeId, highlightId } = {}) {
    this.creativeId = creativeId
    this.highlightAfterLoad = highlightId || null
    this.selection.clear()
    this.notifySelectionChange()
    this.currentPage = 1
    this.allLoaded = false
    this.movingComments = false
    this.manualSearchQuery = null
    this.listTarget.innerHTML = this.element.dataset.loadingText
    this.presenceController?.clearManualTypingMessage()
    this.loadInitialComments()
  }

  onPopupClosed() {
    this.selection.clear()
    this.notifySelectionChange()
    this.listTarget.innerHTML = ''
    this.currentPage = 1
    this.allLoaded = false
    this.movingComments = false
  }



  loadInitialComments() {
    if (!this.creativeId) return
    this.currentPage = 1
    this.allLoaded = false
    this.loadingMore = false
    this.selection.clear()
    this.notifySelectionChange()
    this.listTarget.innerHTML = this.element.dataset.loadingText
    this.fetchCommentsPage(1).then((html) => {
      this.listTarget.innerHTML = html
      renderMarkdownInContainer(this.listTarget)
      this.popupController?.updatePosition()
      this.scrollToBottom()
      this.updateStickiness()
      this.checkAllLoaded(html)
      this.formController?.focusTextarea()
      this.markCommentsRead()
      if (this.highlightAfterLoad) {
        this.highlightComment(this.highlightAfterLoad)
        this.highlightAfterLoad = null
      }
    })
  }

  loadMoreComments() {
    if (this.loadingMore || this.allLoaded || !this.creativeId) return
    this.loadingMore = true
    const nextPage = this.currentPage + 1
    this.fetchCommentsPage(nextPage)
      .then((html) => {
        if (html.trim() === '') {
          this.allLoaded = true
          return
        }
        this.listTarget.insertAdjacentHTML('beforeend', html)
        renderMarkdownInContainer(this.listTarget)
        this.currentPage = nextPage
        this.checkAllLoaded(html)
      })
      .finally(() => {
        this.loadingMore = false
      })
  }

  fetchCommentsPage(page) {
    const params = new URLSearchParams({ page })
    if (this.manualSearchQuery) {
      params.set('search', this.manualSearchQuery)
    }
    return fetch(`/creatives/${this.creativeId}/comments?${params.toString()}`).then((response) => response.text())
  }

  highlightComment(commentId) {
    const comment = document.getElementById(`comment_${commentId}`)
    if (!comment) return
    comment.scrollIntoView({ behavior: 'smooth', block: 'center' })
    comment.classList.add('highlight-flash')
    window.setTimeout(() => comment.classList.remove('highlight-flash'), 2000)
  }

  markCommentsRead() {
    if (!this.creativeId) return
    window.setTimeout(() => {
      fetch('/comment_read_pointers/update', {
        method: 'POST',
        headers: {
          'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ creative_id: this.creativeId }),
      })
    }, 2000);
  }

  handleScroll() {
    this.updateStickiness()
    const pos = this.listTarget.scrollHeight - this.listTarget.clientHeight + this.listTarget.scrollTop
    if (pos < 50) {
      this.loadMoreComments()
    }
  }

  handleChange(event) {
    const checkbox = event.target instanceof Element ? event.target.closest('.comment-select-checkbox') : null
    if (!checkbox) return
    this.handleSelectionChange(checkbox)
  }

  handleClick(event) {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    if (target.closest('.comment-select-checkbox')) {
      return
    }

    const copyBtn = target.closest('.copy-comment-link-btn')
    if (copyBtn) {
      event.preventDefault()
      this.copyCommentLink(copyBtn)
      return
    }

    const editActionBtn = target.closest('.edit-comment-action-btn')
    if (editActionBtn) {
      event.preventDefault()
      this.openActionEditor(this.getActionContainer(editActionBtn))
      return
    }

    const cancelActionEditBtn = target.closest('.cancel-comment-action-edit-btn')
    if (cancelActionEditBtn) {
      event.preventDefault()
      this.closeActionEditor(this.getActionContainer(cancelActionEditBtn))
      return
    }

    if (target.classList.contains('delete-comment-btn')) {
      event.preventDefault()
      this.deleteComment(target)
      return
    }

    if (target.classList.contains('convert-comment-btn')) {
      event.preventDefault()
      this.convertComment(target)
      return
    }

    if (target.classList.contains('approve-comment-btn')) {
      event.preventDefault()
      this.approveComment(target)
      return
    }

    if (target.classList.contains('edit-comment-btn')) {
      event.preventDefault()
      this.editComment(target)
      return
    }
  }

  handleSubmit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    if (!form.classList.contains('comment-action-edit-form')) return
    event.preventDefault()
    this.updateCommentAction(form)
  }

  handleSelectionChange(checkbox) {
    const commentId = checkbox.value
    const item = checkbox.closest('.comment-item')
    if (checkbox.checked) {
      this.selection.add(commentId)
      if (item) item.classList.add('selected-for-move')
    } else {
      this.selection.delete(commentId)
      if (item) item.classList.remove('selected-for-move')
    }
    this.notifySelectionChange()
  }

  notifySelectionChange() {
    const size = this.selection.size
    this.formController?.onSelectionChanged({ size, moving: this.movingComments })
  }

  clearSelection() {
    this.selection.clear()
    this.listTarget.querySelectorAll('.comment-select-checkbox').forEach((checkbox) => {
      checkbox.checked = false
      const item = checkbox.closest('.comment-item')
      if (item) item.classList.remove('selected-for-move')
    })
    this.notifySelectionChange()
  }

  copyCommentLink(button) {
    let url = button.getAttribute('data-comment-url')
    const commentId = button.getAttribute('data-comment-id')
    if (!url && commentId && this.creativeId) {
      const baseUrl = new URL(`${window.location.origin}/creatives/${this.creativeId}`)
      baseUrl.searchParams.set('comment_id', commentId)
      baseUrl.hash = `comment_${commentId}`
      url = baseUrl.toString()
    }
    if (!url) return
    const commentElement = button.closest('.comment-item')
    copyTextToClipboard(url)
      .then(() => this.showCopyFeedback(commentElement, this.element.dataset.copyLinkSuccessText))
      .catch(() => this.showCopyFeedback(commentElement, this.element.dataset.copyLinkErrorText))
  }

  showCopyFeedback(commentElement, message) {
    if (!commentElement || !message) return
    const existing = commentElement.querySelector('.comment-copy-notice')
    if (existing) existing.remove()
    const notice = document.createElement('div')
    notice.className = 'comment-copy-notice'
    notice.textContent = message
    commentElement.appendChild(notice)
    requestAnimationFrame(() => {
      notice.classList.add('visible')
    })
    setTimeout(() => notice.classList.remove('visible'), 2000)
    setTimeout(() => notice.remove(), 2400)
  }

  deleteComment(button) {
    if (!confirm(this.element.dataset.deleteConfirmText)) return
    const commentId = button.getAttribute('data-comment-id')
    fetch(`/creatives/${this.creativeId}/comments/${commentId}`, {
      method: 'DELETE',
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
    }).then((response) => {
      if (response.ok) {
        this.selection.delete(commentId)
        this.notifySelectionChange()
        this.loadInitialComments()
      }
    })
  }

  convertComment(button) {
    if (!confirm(this.element.dataset.convertConfirmText)) return
    const commentId = button.getAttribute('data-comment-id')
    fetch(`/creatives/${this.creativeId}/comments/${commentId}/convert`, {
      method: 'POST',
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
    }).then((response) => {
      if (response.ok) {
        this.loadInitialComments()
      }
    })
  }

  approveComment(button) {
    if (button.disabled) return
    button.disabled = true
    const commentId = button.getAttribute('data-comment-id')
    fetch(`/creatives/${this.creativeId}/comments/${commentId}/approve`, {
      method: 'POST',
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
    })
      .then((response) => {
        if (response.ok) return response.text()
        return response
          .json()
          .then((json) => {
            throw new Error(json?.error || this.element.dataset.approveErrorText)
          })
          .catch((error) => {
            throw error instanceof Error ? error : new Error(this.element.dataset.approveErrorText)
          })
      })
      .then((html) => {
        if (!html) {
          button.disabled = false
          return
        }
        const existing = document.getElementById(`comment_${commentId}`)
        if (existing) {
          existing.outerHTML = html
          const updated = document.getElementById(`comment_${commentId}`)
          if (updated) {
            this.showCopyFeedback(updated, this.element.dataset.approveSuccessText)
          }
        } else {
          button.disabled = false
        }
      })
      .catch((error) => {
        button.disabled = false
        alert(error?.message || this.element.dataset.approveErrorText)
      })
  }

  editComment(button) {
    const commentId = button.getAttribute('data-comment-id')
    const content = button.getAttribute('data-comment-content')
    const isPrivate = button.getAttribute('data-comment-private') === 'true'
    this.formController?.startEditing({ id: commentId, content, private: isPrivate })
  }

  updateCommentAction(form) {
    const submitButton = form.querySelector('.save-comment-action-btn')
    if (submitButton && submitButton.disabled) return
    if (submitButton) submitButton.disabled = true
    const textareaField = form.querySelector('.comment-action-edit-textarea')
    if (!textareaField) {
      if (submitButton) submitButton.disabled = false
      return
    }
    const commentId = form.getAttribute('data-comment-id')
    fetch(`/creatives/${this.creativeId}/comments/${commentId}/update_action`, {
      method: 'PATCH',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ comment: { action: textareaField.value } }),
    })
      .then((response) => {
        if (response.ok) return response.text()
        return response
          .json()
          .then((json) => {
            throw new Error(json?.error || this.element.dataset.actionUpdateErrorText)
          })
          .catch((error) => {
            throw error instanceof Error ? error : new Error(this.element.dataset.actionUpdateErrorText)
          })
      })
      .then((html) => {
        if (!html) return
        const existing = document.getElementById(`comment_${commentId}`)
        if (existing) {
          existing.outerHTML = html
          const updated = document.getElementById(`comment_${commentId}`)
          if (updated) {
            this.showCopyFeedback(updated, this.element.dataset.actionUpdateSuccessText)
          }
        }
        this.closeActionEditor(this.getActionContainer(form))
      })
      .catch((error) => {
        alert(error?.message || this.element.dataset.actionUpdateErrorText)
      })
      .finally(() => {
        if (submitButton) submitButton.disabled = false
      })
  }

  openMoveModal() {
    if (this.movingComments) return
    if (this.selection.size === 0) {
      if (this.element.dataset.moveNoSelectionText) {
        alert(this.element.dataset.moveNoSelectionText)
      }
      return
    }
    this.movingComments = true
    this.notifySelectionChange()

    const opened = openLinkSelection({
      anchorRect: this.element.getBoundingClientRect(),
      onSelect: (item) => this.moveSelectedComments(item.id),
      onClose: () => {
        this.movingComments = false
        this.notifySelectionChange()
      },
    })

    if (!opened) {
      this.movingComments = false
      this.notifySelectionChange()
      alert(this.element.dataset.moveErrorText)
    }
  }

  moveSelectedComments(targetCreativeId) {
    if (!targetCreativeId || this.selection.size === 0) return
    const commentIds = Array.from(this.selection)
    fetch(`/creatives/${this.creativeId}/comments/move`, {
      method: 'POST',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({ comment_ids: commentIds, target_creative_id: targetCreativeId }),
    })
      .then((response) => {
        if (response.ok) return response.json().catch(() => ({}))
        return response
          .json()
          .catch(() => ({}))
          .then((data) => {
            throw new Error(data?.error || this.element.dataset.moveErrorText)
          })
      })
      .then(() => {
        this.loadInitialComments()
        this.clearSelection()
      })
      .catch((error) => {
        alert(error?.message || this.element.dataset.moveErrorText)
      })
      .finally(() => {
        this.movingComments = false
        this.notifySelectionChange()
      })
  }

  applySearchQuery(query) {
    this.manualSearchQuery = query
    this.loadInitialComments()
    if (this.listTarget) {
      this.listTarget.scrollTo({ top: 0 })
    }
  }

  observeListMutations() {
    if (!window.MutationObserver) return
    this.listObserver = new MutationObserver((mutations) => {
      const hasAddedNodes = mutations.some((mutation) => mutation.addedNodes && mutation.addedNodes.length > 0)
      if (hasAddedNodes && this.stickToBottom) {
        requestAnimationFrame(() => this.scrollToBottom())
      }
    })
    this.listObserver.observe(this.listTarget, { childList: true })
  }

  scrollToBottom() {
    if (this.isColumnReverse()) {
      this.listTarget.scrollTop = 0
    } else {
      this.listTarget.scrollTop = this.listTarget.scrollHeight
    }
    this.stickToBottom = true
  }

  updateStickiness() {
    this.stickToBottom = this.isNearBottom()
  }

  isNearBottom() {
    if (this.isColumnReverse()) {
      return Math.abs(this.listTarget.scrollTop) <= 50
    }
    return this.listTarget.scrollHeight - this.listTarget.clientHeight - this.listTarget.scrollTop <= 50
  }

  isColumnReverse() {
    if (!this.computedStyle) {
      this.computedStyle = window.getComputedStyle ? window.getComputedStyle(this.listTarget) : null
    }
    return this.computedStyle?.flexDirection === 'column-reverse'
  }

  checkAllLoaded(html) {
    const count = (html.match(/class="comment-item /g) || []).length
    if (count < COMMENTS_PER_PAGE) {
      this.allLoaded = true
    }
  }

  getActionContainer(element) {
    if (!element) return null
    return element.closest('.comment-action-block')
  }

  openActionEditor(container) {
    if (!container) return
    const jsonDisplay = container.querySelector('.comment-action-json')
    const form = container.querySelector('.comment-action-edit-form')
    const editBtn = container.querySelector('.edit-comment-action-btn')
    if (!jsonDisplay || !form) return
    const textareaField = form.querySelector('.comment-action-edit-textarea')
    if (!textareaField) return
    textareaField.value = jsonDisplay.textContent || ''
    form.style.display = 'block'
    if (editBtn) editBtn.style.display = 'none'
    jsonDisplay.style.display = 'none'
    textareaField.focus()
    if (textareaField.setSelectionRange) {
      const length = textareaField.value.length
      textareaField.setSelectionRange(length, length)
    }
  }

  closeActionEditor(container) {
    if (!container) return
    const jsonDisplay = container.querySelector('.comment-action-json')
    const form = container.querySelector('.comment-action-edit-form')
    const editBtn = container.querySelector('.edit-comment-action-btn')
    if (form) form.style.display = 'none'
    if (jsonDisplay) jsonDisplay.style.display = ''
    if (editBtn) editBtn.style.display = ''
  }
}
