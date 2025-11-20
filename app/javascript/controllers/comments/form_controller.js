import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['form', 'textarea', 'submit', 'privateCheckbox', 'cancel', 'moveButton', 'searchButton', 'voiceButton']

  connect() {
    this.creativeId = null
    this.editingId = null
    this.sending = false

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

    this.formTarget.addEventListener('submit', this.handleSubmit)
    this.submitTarget.addEventListener('click', this.handleSend)
    this.submitTarget.addEventListener('pointerup', this.handlePointerSend)
    this.submitTarget.addEventListener('touchend', this.handleTouchSend, { passive: false })
    this.cancelTarget?.addEventListener('click', this.handleCancel)
    this.moveButtonTarget?.addEventListener('click', this.handleMoveClick)
    this.searchButtonTarget?.addEventListener('click', this.handleSearch)
    this.voiceButtonTarget?.addEventListener('click', this.handleVoiceToggle)

    this.recognition = null
    this.listening = false
    this.recognitionActive = false

    this.textareaTarget.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey) {
        this.handleSend(event)
      }
    })
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
    this.submitTarget.textContent = this.element.dataset.updateCommentText
    if (this.cancelTarget) this.cancelTarget.style.display = ''
    this.focusTextarea()
  }

  resetForm() {
    this.formTarget.reset()
    this.editingId = null
    this.submitTarget.innerHTML = this.defaultSubmitHTML
    if (this.cancelTarget) this.cancelTarget.style.display = 'none'
    this.presenceController?.clearManualTypingMessage()
  }

  handleSubmit(event) {
    event.preventDefault()
    this.handleSend(event)
  }

  handleSend(event) {
    event.preventDefault()
    if (this.sending || !this.textareaTarget.value.trim() || !this.creativeId) return
    this.sending = true
    this.presenceController?.stoppedTyping()

    const formData = new FormData(this.formTarget)
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
        const isPrivate = this.privateCheckboxTarget?.checked
        this.resetForm()
        if (wasEditing) {
          this.listController?.markCommentsRead()
        } else if (isPrivate) {
          const listElement = document.getElementById('comments_list')
          if (listElement) listElement.insertAdjacentHTML('beforeend', html)
        }
        this.listController?.scrollToBottom()
        this.listController?.updateStickiness()
        this.listController?.markCommentsRead()
      })
      .catch((error) => {
        alert(error?.message || 'Failed to submit comment')
      })
      .finally(() => {
        this.sending = false
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
    if (this.recognitionActive) {
      this.recognition.stop()
    } else {
      this.updateVoiceButton(false)
    }
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
    const transcript = Array.from(event.results)
      .map((result) => result[0]?.transcript)
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
    alert(this.element.dataset.speechErrorText || 'Unable to start voice input')
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
    this.listening = false
    this.recognitionActive = false
    this.recognition.removeEventListener('start', this.handleRecognitionStart)
    this.recognition.removeEventListener('end', this.handleRecognitionEnd)
    this.recognition.removeEventListener('result', this.handleRecognitionResult)
    this.recognition.removeEventListener('error', this.handleRecognitionError)
    this.recognition.stop()
    this.recognition = null
  }
}
