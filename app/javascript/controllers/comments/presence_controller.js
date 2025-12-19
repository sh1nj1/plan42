import { Controller } from '@hotwired/stimulus'
import { createSubscription } from '../../services/cable'

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
