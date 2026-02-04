import { Controller } from '@hotwired/stimulus'
import { createSubscription } from '../../services/cable'
import { renderCommentMarkdown } from '../../lib/utils/markdown'

const TYPING_TIMEOUT = 3000

export default class extends Controller {
  static targets = ['participants', 'typingIndicator', 'textarea', 'privateCheckbox']

  connect() {
    this.creativeId = null
    this.participantsData = null
    this.currentPresentIds = []
    this.typingUsers = {}
    this.typingTimers = {}
    this.manualTypingMessage = null
    this.presenceSubscription = null
    this.typingTimeoutHandle = null
    this.hasPresenceConnected = false

    this.handleInput = this.handleInput.bind(this)
    this.handleFocus = this.handleFocus.bind(this)
    this.handleBlur = this.handleBlur.bind(this)

    this.textareaTarget.addEventListener('input', this.handleInput)
    this.textareaTarget.addEventListener('focus', this.handleFocus)
    this.textareaTarget.addEventListener('blur', this.handleBlur)
    this.privateCheckboxTarget?.addEventListener('change', () => this.stoppedTyping())
  }

  disconnect() {
    this.unsubscribe()
    this.textareaTarget.removeEventListener('input', this.handleInput)
    this.textareaTarget.removeEventListener('focus', this.handleFocus)
    this.textareaTarget.removeEventListener('blur', this.handleBlur)
  }

  get listController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--list')
  }

  onPopupOpened({ creativeId }) {
    this.creativeId = creativeId
    this.loadParticipants()
    this.subscribe()
    this.renderParticipants([])
    this.renderTypingIndicator()
  }

  onPopupClosed() {
    this.unsubscribe()
    this.participantsData = null
    this.currentPresentIds = []
    this.typingUsers = {}
    this.clearTypingTimers()
    this.clearManualTypingMessage()
    this.renderParticipants([])
    this.renderTypingIndicator()
    this.element.style.bottom = ''
  }

  setManualTypingMessage(message) {
    this.manualTypingMessage = message || null
    this.renderTypingIndicator()
  }

  clearManualTypingMessage() {
    if (this.manualTypingMessage !== null) {
      this.manualTypingMessage = null
      this.renderTypingIndicator()
    }
  }

  typing() {
    if (!this.presenceSubscription || this.privateCheckboxTarget?.checked) return
    this.presenceSubscription.perform('typing')
    this.resetTypingTimeout()
  }

  stoppedTyping() {
    if (this.presenceSubscription) {
      this.presenceSubscription.perform('stopped_typing')
    }
    if (this.typingTimeoutHandle) {
      clearTimeout(this.typingTimeoutHandle)
      this.typingTimeoutHandle = null
    }
  }

  loadParticipants() {
    if (!this.creativeId) return
    fetch(`/creatives/${this.creativeId}/comments/participants`)
      .then((response) => response.json())
      .then((data) => {
        this.participantsData = data
        this.renderParticipants(this.currentPresentIds)
        this.renderTypingIndicator()
      })
  }

  subscribe() {
    if (!this.creativeId) return
    this.unsubscribe()
    this.hasPresenceConnected = false
    this.presenceSubscription = createSubscription(
      { channel: 'CommentsPresenceChannel', creative_id: this.creativeId },
      {
        connected: () => {
          if (this.hasPresenceConnected) {
            this.listController?.loadInitialComments()
          }
          this.hasPresenceConnected = true
        },
        received: (data) => this.handlePresenceMessage(data),
      },
    )
  }

  unsubscribe() {
    if (this.presenceSubscription) {
      this.presenceSubscription.unsubscribe()
      this.presenceSubscription = null
    }
    this.stoppedTyping()
  }

  handlePresenceMessage(data) {
    if (data.ids) {
      this.currentPresentIds = data.ids.map((id) => parseInt(id, 10))
      this.renderParticipants(this.currentPresentIds)
      this.updateReadReceiptPresence(this.currentPresentIds)
    }
    if (data.typing) {
      const { id, name } = data.typing
      this.typingUsers[id] = name
      this.renderTypingIndicator()
      clearTimeout(this.typingTimers[id])
      this.typingTimers[id] = setTimeout(() => {
        delete this.typingUsers[id]
        delete this.typingTimers[id]
        this.renderTypingIndicator()
      }, TYPING_TIMEOUT)
    }
    if (data.stop_typing) {
      const { id } = data.stop_typing
      delete this.typingUsers[id]
      if (this.typingTimers[id]) {
        clearTimeout(this.typingTimers[id])
        delete this.typingTimers[id]
      }
      this.renderTypingIndicator()
    }
    if (data.agent_status) {
      const { id, name, status, task_id: taskId, content, topic_id: topicId } = data.agent_status
      if (status === 'thinking' || status === 'streaming') {
        this.typingUsers[id] = name
        if (this.isCurrentTopic(topicId)) {
          this.updateStreamingElement(id, name, taskId, content)
        }
      } else {
        delete this.typingUsers[id]
        this.removeStreamingElement(taskId)
      }
      this.renderTypingIndicator()
    }
  }

  renderParticipants(presentIds) {
    if (!this.hasParticipantsTarget || !this.participantsData) {
      if (this.hasParticipantsTarget) this.participantsTarget.innerHTML = ''
      return
    }
    this.participantsTarget.innerHTML = ''
    this.participantsData.forEach((user) => {
      const wrapper = document.createElement('div')
      wrapper.className = 'avatar-wrapper'
      wrapper.style.width = '20px'
      wrapper.style.height = '20px'

      const img = document.createElement('img')
      img.src = user.avatar_url
      img.alt = ''
      img.width = 20
      img.height = 20
      img.className = 'avatar comment-presence-avatar'
      if (presentIds.indexOf(user.id) === -1) {
        img.classList.add('inactive')
      }
      img.title = user.name
      img.style.borderRadius = '50%'
      if (user.email) img.dataset.email = user.email
      img.dataset.userId = user.id
      img.dataset.userName = user.name
      wrapper.appendChild(img)

      if (user.default_avatar) {
        const span = document.createElement('span')
        span.className = 'avatar-initial'
        span.textContent = user.initial
        span.style.fontSize = `${Math.round(20 / 2)}px`
        wrapper.appendChild(span)
      }

      this.participantsTarget.appendChild(wrapper)
    })

    this.updateReadReceiptPresence(presentIds)
  }

  renderTypingIndicator() {
    if (!this.hasTypingIndicatorTarget) return
    this.typingIndicatorTarget.innerHTML = ''

    if (this.manualTypingMessage) {
      const message = document.createElement('span')
      message.textContent = this.manualTypingMessage
      this.typingIndicatorTarget.style.visibility = 'visible'
      this.typingIndicatorTarget.appendChild(message)
      return
    }

    const ids = Object.keys(this.typingUsers)
    if (ids.length === 0) {
      this.typingIndicatorTarget.style.visibility = 'hidden'
      return
    }

    this.typingIndicatorTarget.style.visibility = 'visible'
    if (this.participantsData) {
      ids.forEach((id) => {
        const user = this.participantsData.find((participant) => participant.id === parseInt(id, 10))
        if (!user) return
        const wrapper = document.createElement('span')
        wrapper.className = 'avatar-wrapper'
        const img = document.createElement('img')
        img.src = user.avatar_url
        img.alt = ''
        img.width = 20
        img.height = 20
        img.className = 'avatar comment-presence-avatar'
        img.style.borderRadius = '50%'
        wrapper.appendChild(img)
        if (user.default_avatar) {
          const span = document.createElement('span')
          span.className = 'avatar-initial'
          span.textContent = user.initial
          span.style.fontSize = `${Math.round(20 / 2)}px`
          wrapper.appendChild(span)
        }
        this.typingIndicatorTarget.appendChild(wrapper)
      })
    }
    const names = ids.map((id) => this.typingUsers[id])
    const text = document.createElement('span')
    text.textContent = `${names.join(', ')} ...`
    this.typingIndicatorTarget.appendChild(text)
  }

  isCurrentTopic(topicId) {
    const list = document.getElementById('comments-list')
    if (!list) return true
    const currentTopicId = list.dataset.currentTopicId || ''
    const streamTopicId = (topicId === null || topicId === undefined) ? '' : String(topicId)
    // Show if no topic filter is set, or if topics match
    return currentTopicId === '' || currentTopicId === streamTopicId
  }

  updateStreamingElement(agentId, agentName, taskId, content) {
    if (!content && content !== '') return
    const list = document.getElementById('comments-list')
    if (!list) return

    const elementId = `agent-streaming-${taskId}`
    let el = document.getElementById(elementId)

    if (!el) {
      el = document.createElement('div')
      el.id = elementId
      el.className = 'comment-item agent-streaming'
      el.dataset.taskId = taskId
      list.appendChild(el)
    }

    // Build header only once, update content efficiently
    let headerEl = el.querySelector('.agent-streaming-header')
    if (!headerEl) {
      el.textContent = ''

      headerEl = document.createElement('div')
      headerEl.className = 'agent-streaming-header'

      if (this.participantsData) {
        const user = this.participantsData.find((p) => p.id === agentId)
        if (user) {
          const img = document.createElement('img')
          img.src = user.avatar_url
          img.alt = ''
          img.width = 20
          img.height = 20
          img.className = 'avatar comment-avatar'
          img.style.borderRadius = '50%'
          headerEl.appendChild(img)
        }
      }

      const strong = document.createElement('strong')
      strong.textContent = agentName
      headerEl.appendChild(strong)

      // Stop button
      const stopBtn = document.createElement('button')
      stopBtn.className = 'stop-streaming-btn'
      stopBtn.type = 'button'
      stopBtn.textContent = '⏹'
      stopBtn.title = this.element.dataset.stopStreamingText || 'Stop'
      stopBtn.addEventListener('click', () => this.stopStreaming(taskId))
      headerEl.appendChild(stopBtn)

      el.appendChild(headerEl)

      const contentEl = document.createElement('div')
      contentEl.className = 'comment-content'
      el.appendChild(contentEl)
    }

    // Update content with markdown rendering
    const contentEl = el.querySelector('.comment-content')
    if (contentEl) {
      contentEl.innerHTML = renderCommentMarkdown(content)
    }

    // Auto-scroll to bottom
    list.scrollTop = list.scrollHeight
  }

  stopStreaming(taskId) {
    if (!taskId || !this.creativeId) return

    const btn = document.querySelector(`#agent-streaming-${taskId} .stop-streaming-btn`)
    if (btn) btn.disabled = true

    fetch(`/creatives/${this.creativeId}/comments/stop_streaming`, {
      method: 'POST',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ task_id: taskId }),
    }).catch((err) => {
      console.error('Failed to stop streaming:', err)
      if (btn) btn.disabled = false
    })
  }

  removeStreamingElement(taskId) {
    if (!taskId) return
    const el = document.getElementById(`agent-streaming-${taskId}`)
    if (el) el.remove()
  }

  clearTypingTimers() {
    Object.values(this.typingTimers).forEach((timer) => clearTimeout(timer))
    this.typingTimers = {}
  }

  handleInput() {
    this.clearManualTypingMessage()
    this.typing()
  }

  handleFocus() {
    if (!this.isMobile()) return
    this.adjustForKeyboard()
    if (window.visualViewport) {
      this.visualViewportHandler = () => this.adjustForKeyboard()
      window.visualViewport.addEventListener('resize', this.visualViewportHandler)
    }
  }

  handleBlur() {
    this.stoppedTyping()
    if (this.typingTimeoutHandle) {
      clearTimeout(this.typingTimeoutHandle)
      this.typingTimeoutHandle = null
    }
    this.element.style.bottom = ''
    if (window.visualViewport && this.visualViewportHandler) {
      window.visualViewport.removeEventListener('resize', this.visualViewportHandler)
      this.visualViewportHandler = null
    }
  }

  resetTypingTimeout() {
    if (this.typingTimeoutHandle) clearTimeout(this.typingTimeoutHandle)
    this.typingTimeoutHandle = setTimeout(() => this.stoppedTyping(), TYPING_TIMEOUT)
  }

  adjustForKeyboard() {
    if (!this.isMobile()) return
    let inset = 0
    if (window.visualViewport) {
      const vv = window.visualViewport
      inset = window.innerHeight - (vv.height + vv.offsetTop)
      if (inset < 0) inset = 0
    }
    this.element.style.bottom = `${inset}px`
  }

  isMobile() {
    return window.innerWidth <= 600
  }

  updateReadReceiptPresence(presentIds = []) {
    const avatars = this.element.querySelectorAll('.read-receipt-avatars .comment-presence-avatar')
    const presentLookup = new Set(presentIds)

    avatars.forEach((avatar) => {
      const userId = parseInt(avatar.dataset.userId, 10)
      if (Number.isNaN(userId)) return
      if (presentLookup.has(userId)) {
        avatar.classList.remove('inactive')
      } else {
        avatar.classList.add('inactive')
      }
    })
  }
}
