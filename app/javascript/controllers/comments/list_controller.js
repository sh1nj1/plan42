import { Controller } from '@hotwired/stimulus'
import { copyTextToClipboard } from '../../utils/clipboard'

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
    this.listTarget.innerHTML = this.element.dataset.loadingText
    this.clearSearchFilter()
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

  listHeight() {
    return this.listTarget.offsetHeight
  }

  adjustListHeight(containerHeight) {
    const reserved = containerHeight - this.listHeight()
    this.reservedHeight = reserved
  }

  setListHeight(height) {
    if (height > 0) {
      this.listTarget.style.height = `${height}px`
    }
  }

  loadInitialComments() {
    if (!this.creativeId) return
    this.fetchCommentsPage(1).then((html) => {
      this.listTarget.innerHTML = html
      this.selection.clear()
      this.notifySelectionChange()
      this.renderMarkdown(this.listTarget)
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
        this.renderMarkdown(this.listTarget)
        this.currentPage = nextPage
        this.checkAllLoaded(html)
      })
      .finally(() => {
        this.loadingMore = false
      })
  }

  fetchCommentsPage(page) {
    return fetch(`/creatives/${this.creativeId}/comments?page=${page}`).then((response) => response.text())
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
    fetch('/comment_read_pointers/update', {
      method: 'POST',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ creative_id: this.creativeId }),
    })
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
    const linkModal = document.getElementById('link-creative-modal')
    const linkSearchInput = document.getElementById('link-creative-search')
    const linkResults = document.getElementById('link-creative-results')
    if (!linkModal || !linkSearchInput || !linkResults) {
      alert(this.element.dataset.moveErrorText)
      return
    }

    const cleanup = () => {
      linkModal.removeEventListener('link-creative-modal:select', handleSelect)
      linkModal.removeEventListener('link-creative-modal:closed', handleClosed)
    }

    const handleSelect = (event) => {
      cleanup()
      const detail = event?.detail || {}
      if (detail.id) {
        this.moveSelectedComments(detail.id)
      }
    }

    const handleClosed = () => {
      cleanup()
      this.movingComments = false
      this.notifySelectionChange()
    }

    this.movingComments = true
    this.notifySelectionChange()

    linkModal.addEventListener('link-creative-modal:select', handleSelect)
    linkModal.addEventListener('link-creative-modal:closed', handleClosed)
    linkModal.dataset.context = 'comment-move'
    linkSearchInput.value = ''
    linkResults.innerHTML = ''
    linkModal.style.display = 'flex'
    document.body.classList.add('no-scroll')
    requestAnimationFrame(() => linkSearchInput.focus())
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

  filterCommentsByQuery(query) {
    if (!query) {
      this.clearSearchFilter()
      this.presenceController?.setManualTypingMessage(this.element.dataset.searchEmptyText)
      return 0
    }
    const normalized = query.toLowerCase()
    let matches = 0
    this.listTarget.querySelectorAll('.comment-item').forEach((item) => {
      const contentEl = item.querySelector('.comment-content')
      const text = contentEl ? contentEl.textContent || '' : item.textContent || ''
      if (text.toLowerCase().includes(normalized)) {
        item.style.display = ''
        matches += 1
      } else {
        item.style.display = 'none'
      }
    })
    if (matches === 0) {
      this.presenceController?.setManualTypingMessage(this.element.dataset.searchEmptyText)
    } else {
      this.presenceController?.clearManualTypingMessage()
    }
    return matches
  }

  clearSearchFilter() {
    this.listTarget.querySelectorAll('.comment-item').forEach((item) => {
      item.style.display = ''
    })
    this.presenceController?.clearManualTypingMessage()
  }

  renderMarkdown(container) {
    if (!window.marked) return
    container.querySelectorAll('.comment-content').forEach((element) => {
      if (element.dataset.rendered === 'true') return
      element.innerHTML = window.marked.parse(element.textContent)
      element.dataset.rendered = 'true'
    })
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
