import { Controller } from '@hotwired/stimulus'
import { renderMarkdownInContainer } from '../../lib/utils/markdown'

export default class extends Controller {
  static targets = [
    'form',
    'textarea',
    'submit',
    'privateCheckbox',
    'cancel',
    'moveButton',
    'searchButton',
    'voiceButton',
    'imageInput',
    'imageButton',
    'attachmentList',
  ]

  connect() {
    this.creativeId = null
    this.editingId = null
    this.sending = false
    this.cachedImageFiles = null

    this.handleSubmit = this.handleSubmit.bind(this)
    this.handleSend = this.handleSend.bind(this)
    this.defaultSubmitHTML = this.submitTarget.innerHTML
    this.handlePointerSend = this.handlePointerSend.bind(this)
    this.handleTouchSend = this.handleTouchSend.bind(this)
    this.handleCancel = this.handleCancel.bind(this)
    this.handleMoveClick = this.handleMoveClick.bind(this)
    this.handleSearch = this.handleSearch.bind(this)
    this.handleVoiceToggle = this.handleVoiceToggle.bind(this)
    this.handleRecognitionStart = this.handleRecognitionStart.bind(this)
    this.handleRecognitionEnd = this.handleRecognitionEnd.bind(this)
    this.handleRecognitionResult = this.handleRecognitionResult.bind(this)
    this.handleRecognitionError = this.handleRecognitionError.bind(this)
    this.handleImageButtonClick = this.handleImageButtonClick.bind(this)
    this.handleImageChange = this.handleImageChange.bind(this)
    this.handleDragOver = this.handleDragOver.bind(this)
    this.handleDrop = this.handleDrop.bind(this)

    this.formTarget.addEventListener('submit', this.handleSubmit)
    this.submitTarget.addEventListener('click', this.handleSend)
    this.submitTarget.addEventListener('pointerup', this.handlePointerSend)
    this.submitTarget.addEventListener('touchend', this.handleTouchSend, { passive: false })
    this.cancelTarget?.addEventListener('click', this.handleCancel)
    this.moveButtonTarget?.addEventListener('click', this.handleMoveClick)
    this.searchButtonTarget?.addEventListener('click', this.handleSearch)
    this.voiceButtonTarget?.addEventListener('click', this.handleVoiceToggle)

    this.imageButtonTarget?.addEventListener('click', this.handleImageButtonClick)
    this.imageInputTarget?.addEventListener('change', this.handleImageChange)
    this.textareaTarget.addEventListener('dragover', this.handleDragOver)
    this.textareaTarget.addEventListener('drop', this.handleDrop)


    this.recognition = null
    this.listening = false
    this.recognitionActive = false

    this.textareaTarget.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey) {
        if (this.isMentionMenuVisible()) return
        this.handleSend(event)
      }
    })

    this.updateAttachmentList()

    this.handleTopicChange = this.handleTopicChange.bind(this)
    this.element.addEventListener('comments--topics:change', this.handleTopicChange)
  }

  handleTopicChange(event) {
    this.currentTopicId = event.detail.topicId
  }


  isMentionMenuVisible() {
    const menu = document.getElementById('mention-menu')
    return menu?.style.display === 'block'
  }

  disconnect() {
    this.formTarget.removeEventListener('submit', this.handleSubmit)
    this.submitTarget.removeEventListener('click', this.handleSend)
    this.submitTarget.removeEventListener('pointerup', this.handlePointerSend)
    this.submitTarget.removeEventListener('touchend', this.handleTouchSend)
    this.cancelTarget?.removeEventListener('click', this.handleCancel)
    this.moveButtonTarget?.removeEventListener('click', this.handleMoveClick)
    this.searchButtonTarget?.removeEventListener('click', this.handleSearch)
    this.voiceButtonTarget?.removeEventListener('click', this.handleVoiceToggle)
    this.teardownSpeechRecognition()
    this.imageButtonTarget?.removeEventListener('click', this.handleImageButtonClick)
    this.imageInputTarget?.removeEventListener('change', this.handleImageChange)
    this.textareaTarget.removeEventListener('dragover', this.handleDragOver)
    this.textareaTarget.removeEventListener('drop', this.handleDrop)
    this.element.removeEventListener('comments--topics:change', this.handleTopicChange)
  }

  get listController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--list')
  }

  get presenceController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--presence')
  }

  onPopupOpened({ creativeId, canComment }) {
    this.creativeId = creativeId
    this.element.dataset.creativeId = creativeId || ''
    this.formTarget.style.display = canComment ? '' : 'none'
    this.resetForm()
    if (canComment) {
      requestAnimationFrame(() => this.textareaTarget.focus())
    }
  }

  onPopupClosed() {
    this.stopSpeechRecognition()
    this.resetForm()
  }

  onSelectionChanged({ size, moving }) {
    if (!this.moveButtonTarget) return
    this.moveButtonTarget.disabled = moving || size === 0
  }

  focusTextarea() {
    if (this.formTarget.style.display === 'none') return
    requestAnimationFrame(() => this.textareaTarget.focus())
  }

  startEditing({ id, content, private: isPrivate }) {
    this.editingId = id
    this.textareaTarget.value = content || ''
    if (this.privateCheckboxTarget) {
      this.privateCheckboxTarget.checked = !!isPrivate
      this.privateCheckboxTarget.dispatchEvent(new Event('change'))
    }
    this.clearImageAttachments()
    this.submitTarget.textContent = this.element.dataset.updateCommentText
    if (this.cancelTarget) this.cancelTarget.style.display = ''
    this.focusTextarea()
  }

  resetForm() {
    this.formTarget.reset()
    this.editingId = null
    this.submitTarget.innerHTML = this.defaultSubmitHTML
    this.submitTarget.disabled = false
    if (this.cancelTarget) this.cancelTarget.style.display = 'none'
    this.presenceController?.clearManualTypingMessage()
    this.clearImageAttachments()
  }

  setSendingState(isSending) {
    if (!this.submitTarget) return

    if (isSending) {
      this.submitTarget.disabled = true
      return
    }

    this.submitTarget.disabled = false
    this.sending = false
  }

  handleSubmit(event) {
    event.preventDefault()
    this.handleSend(event)
  }

  handleSend(event) {
    event.preventDefault()
    const hasText = this.textareaTarget.value.trim().length > 0
    const hasImages = this.currentImageFiles().length > 0
    if (this.sending || (!hasText && !hasImages) || !this.creativeId) return
    this.sending = true
    this.setSendingState(true)
    this.presenceController?.stoppedTyping()

    const wasPrivate = this.privateCheckboxTarget?.checked ?? false

    const formData = new FormData(this.formTarget)
    if (this.currentTopicId) {
      formData.append('comment[topic_id]', this.currentTopicId)
    }

    let url = `/creatives/${this.creativeId}/comments`
    let method = 'POST'
    if (this.editingId) {
      url += `/${this.editingId}`
      method = 'PATCH'
    }

    fetch(url, {
      method,
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
      body: formData,
    })
      .then((response) => {
        if (response.ok) return response.text()
        return response.json().then((json) => {
          throw new Error(json.errors?.join(', ') || 'Unable to save comment')
        })
      })
      .then((html) => {
        const wasEditing = this.editingId
        this.resetForm()
        if (wasEditing) {
          // If editing, just replace the item in place
          this.renderCommentHtml(html, { replaceExisting: true })
        } else {
          // New Comment:
          // 1. If we are in "History Mode" (scrolled up), sending a message should jump us to the latest.
          // 2. Ideally, we just reload the "Latest" page to ensure sync and Live Mode.
          // 3. Or, if we are already at latest, just append.

          // Based on requirements: "jump to first page... message added immediately".
          // Safest approach: Reset list to latest.
          // However, to make it feel instant, we might want to append optimisticly or just let the reset handle it.
          // A full reset causes a loading spinner.
          // Better UX: Append to bottom, then ensure we are in "Live Mode".

          // BUT, if we are in history, appending to bottom might leave a gap if we haven't loaded intermediate messages.
          // So, if !allNewerLoaded, we MUST reset/reload to get the full latest context.

          const listCtrl = this.listController
          if (listCtrl) {
            if (!listCtrl.allNewerLoaded) {
              // In History Mode -> Reset to Latest
              listCtrl.resetToLatest()
              // Note: The new message is in `html`, but resetToLatest fetches from server.
              // There might be a race condition if server value isn't ready, but usually ok.
              // Alternatively, we manually clear list and append `html` + fetch prev?
              // Reset is safest for data consistency.
            } else {
              // Already in Live Mode or at bottom -> Just append and scroll
              this.renderCommentHtml(html, { replaceExisting: false })
              listCtrl.scrollToBottom()
              listCtrl.updateStickiness()
              listCtrl.markCommentsRead()
            }
          }
        }
      })
      .catch((error) => {
        alert(error?.message || 'Failed to submit comment')
      })
      .finally(() => {
        this.setSendingState(false)
      })
  }

  handlePointerSend(event) {
    if (event.pointerType !== 'mouse') {
      this.handleSend(event)
    }
  }

  handleTouchSend(event) {
    event.preventDefault()
    this.handleSend(event)
  }

  handleCancel(event) {
    event.preventDefault()
    this.resetForm()
  }

  handleMoveClick(event) {
    event.preventDefault()
    this.listController?.openMoveModal()
  }

  handleSearch(event) {
    event.preventDefault()
    const query = this.textareaTarget.value.trim()
    this.presenceController?.clearManualTypingMessage()
    this.listController?.applySearchQuery(query || null)
  }

  handleVoiceToggle(event) {
    event.preventDefault()
    if (this.listening) {
      this.stopSpeechRecognition()
    } else {
      this.startSpeechRecognition()
    }
  }

  setupSpeechRecognition() {
    if (this.recognition) return true

    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SpeechRecognition) {
      alert(this.element.dataset.speechUnavailableText || 'Speech recognition not supported')
      return false
    }

    this.recognition = new SpeechRecognition()
    this.recognition.continuous = true
    this.recognition.interimResults = false
    this.recognition.lang = document.documentElement.lang || 'ko-KR'
    this.recognition.addEventListener('start', this.handleRecognitionStart)
    this.recognition.addEventListener('end', this.handleRecognitionEnd)
    this.recognition.addEventListener('result', this.handleRecognitionResult)
    this.recognition.addEventListener('error', this.handleRecognitionError)
    return true
  }

  startSpeechRecognition() {
    if (!this.setupSpeechRecognition()) return
    if (this.listening) return

    this.listening = true
    this.tryStartRecognition()
  }

  stopSpeechRecognition() {
    this.listening = false
    if (this.recognition) {
      if (this.recognitionActive) {
        this.recognition.stop()
      } else {
        if (this.recognition.abort) this.recognition.abort()
        try {
          this.recognition.stop()
        } catch (error) {
          // ignore invalid state errors from stopping before start
        }
      }
    }
    this.updateVoiceButton(false)
  }

  tryStartRecognition() {
    if (!this.recognition || this.recognitionActive) return
    try {
      this.recognition.start()
    } catch (error) {
      this.handleRecognitionError(error)
    }
  }

  handleRecognitionStart() {
    this.recognitionActive = true
    if (!this.listening) {
      this.recognition.stop()
      return
    }
    this.updateVoiceButton(true)
  }

  handleRecognitionEnd() {
    this.recognitionActive = false
    if (this.listening) {
      this.tryStartRecognition()
    } else {
      this.updateVoiceButton(false)
    }
  }

  handleRecognitionResult(event) {
    const latestResult = event.results[event.resultIndex]
    const transcript = Array.from(latestResult || [])
      .map((result) => result?.transcript)
      .filter(Boolean)
      .join(' ')
      .trim()

    if (!transcript) return

    const currentValue = this.textareaTarget.value
    const needsSpace = currentValue && !currentValue.endsWith(' ')
    this.textareaTarget.value = `${currentValue}${needsSpace ? ' ' : ''}${transcript}`
    this.textareaTarget.dispatchEvent(new Event('input'))
    this.focusTextarea()
  }

  handleRecognitionError() {
    this.listening = false
    this.recognitionActive = false
    this.updateVoiceButton(false)
  }

  updateVoiceButton(active) {
    if (!this.voiceButtonTarget) return
    this.voiceButtonTarget.textContent = active
      ? this.element.dataset.voiceStopText || '중지'
      : this.element.dataset.voiceStartText || '음성'
    this.voiceButtonTarget.classList.toggle('voice-input-active', active)
  }

  teardownSpeechRecognition() {
    if (!this.recognition) return
    this.stopSpeechRecognition()
    this.recognition.removeEventListener('start', this.handleRecognitionStart)
    this.recognition.removeEventListener('end', this.handleRecognitionEnd)
    this.recognition.removeEventListener('result', this.handleRecognitionResult)
    this.recognition.removeEventListener('error', this.handleRecognitionError)
    this.recognition = null
  }

  handleImageButtonClick(event) {
    event.preventDefault()
    this.cachedImageFiles = this.currentImageFiles()
    this.imageInputTarget?.click()
  }

  handleImageChange() {
    if (!this.imageInputTarget) return
    const newFiles = Array.from(this.imageInputTarget.files || [])
    const existingFiles = this.cachedImageFiles ?? []
    this.setImageFiles([...existingFiles, ...newFiles])
    this.cachedImageFiles = null
    this.updateAttachmentList()
  }

  handleDragOver(event) {
    if (this.hasImageFromDataTransfer(event.dataTransfer)) {
      event.preventDefault()
    }
  }

  handleDrop(event) {
    const imageFiles = this.extractImageFiles(event.dataTransfer)
    if (!imageFiles.length) return
    event.preventDefault()
    this.setImageFiles([...this.currentImageFiles(), ...imageFiles])
    this.updateAttachmentList()
  }

  extractImageFiles(dataTransfer) {
    if (!dataTransfer) return []
    const files = Array.from(dataTransfer.files || []).filter((file) => file.type?.startsWith('image/'))
    if (files.length > 0) return files
    if (!dataTransfer.items) return []
    return Array.from(dataTransfer.items)
      .map((item) => (item.kind === 'file' ? item.getAsFile() : null))
      .filter((file) => file && file.type?.startsWith('image/'))
  }

  hasImageFromDataTransfer(dataTransfer) {
    return this.extractImageFiles(dataTransfer).length > 0
  }

  setImageFiles(files) {
    if (!this.imageInputTarget) return
    const dataTransfer = new DataTransfer()
    files.forEach((file) => dataTransfer.items.add(file))
    this.imageInputTarget.files = dataTransfer.files
  }

  currentImageFiles() {
    if (!this.imageInputTarget) return []
    return Array.from(this.imageInputTarget.files || [])
  }

  clearImageAttachments() {
    this.cachedImageFiles = null
    this.setImageFiles([])
    this.updateAttachmentList()
  }

  removeImageAttachment(index) {
    const files = this.currentImageFiles().filter((_, fileIndex) => fileIndex !== index)
    this.setImageFiles(files)
    this.updateAttachmentList()
  }

  updateAttachmentList() {
    if (!this.attachmentListTarget) return
    const files = this.currentImageFiles()
    this.attachmentListTarget.innerHTML = ''
    if (!files.length) {
      this.attachmentListTarget.style.display = 'none'
      return
    }

    this.attachmentListTarget.style.display = ''
    files.forEach((file, index) => {
      const item = document.createElement('span')
      item.className = 'comment-attachment-item'
      item.textContent = file.name

      const removeButton = document.createElement('button')
      removeButton.type = 'button'
      removeButton.className = 'comment-attachment-remove'
      removeButton.setAttribute('aria-label', `Remove ${file.name}`)
      removeButton.textContent = '×'
      removeButton.addEventListener('click', () => this.removeImageAttachment(index))

      item.appendChild(removeButton)
      this.attachmentListTarget.appendChild(item)
    })
  }

  renderCommentHtml(html, { replaceExisting = false } = {}) {
    const listElement = document.getElementById('comments-list')
    if (!listElement || !html) return

    const parser = new DOMParser()
    const doc = parser.parseFromString(html, 'text/html')
    const commentElement = doc.querySelector('.comment-item')
    if (!commentElement) return

    this.removePlaceholder()

    const existing = listElement.querySelector(`#${commentElement.id}`)
    if (existing) {
      existing.replaceWith(commentElement)
    } else {
      listElement.appendChild(commentElement)
    }

    renderMarkdownInContainer(commentElement)
    if (replaceExisting) {
      this.listController?.markCommentsRead()
    }
  }

  removePlaceholder() {
    const listElement = document.getElementById('comments-list')
    const placeholder = listElement?.querySelector('#no-comments')
    if (placeholder) placeholder.remove()
  }
}
