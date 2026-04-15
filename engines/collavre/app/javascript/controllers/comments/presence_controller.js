import { Controller } from '@hotwired/stimulus'
import { createSubscription } from '../../services/cable'
import TouchDragHandler from '../../lib/touch_drag'
import csrfFetch from '../../lib/api/csrf_fetch'

const TYPING_TIMEOUT = 3000
const AGENT_STATUS_TIMEOUT = 10000 // Safety timeout for agent_status (heartbeat expected every 3s)

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
    this.currentUserId = document.body.dataset.currentUserId

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

  get formController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--form')
  }

  get popupController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--popup')
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
    this.activeAgentTasks = {}
    this.syncGlobalAgentTasks()
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

  loadParticipants({ closeOnForbidden = false } = {}) {
    if (!this.creativeId) return
    fetch(`/creatives/${this.creativeId}/comments/participants`, {
      cache: 'no-store',
      headers: { Accept: 'application/json' },
    })
      .then(async (response) => {
        if (!response.ok) {
          const payload = await response.json().catch(() => ({}))
          throw new Error(payload.error || this.element.dataset.noPermissionText || 'No permission')
        }
        return response.json()
      })
      .then((data) => {
        this.participantsData = data.users
        this.canShare = data.can_share
        this.formController?.setCommentPermission(data.can_comment)
        this.renderParticipants(this.currentPresentIds)
        this.renderTypingIndicator()
      })
      .catch((error) => {
        this.participantsData = []
        this.canShare = false
        this.renderParticipants([])
        this.renderTypingIndicator()

        if (closeOnForbidden) {
          alert(error.message)
          this.popupController?.close()
        }
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
    if (data.shares_changed) {
      const shareChange = data.shares_changed
      const affectedCurrentUser = this.currentUserId && String(shareChange.user_id) === String(this.currentUserId)

      if (!affectedCurrentUser) {
        this.loadParticipants()
        return
      }

      if (shareChange.can_comment_changed && typeof shareChange.can_comment === 'boolean') {
        this.formController?.setCommentPermission(shareChange.can_comment)
      }

      this.loadParticipants({ closeOnForbidden: shareChange.has_access === false })
      return
    }
    if (data.agent_status) {
      const { id, name, status, task_id, creative_id: agentCreativeId } = data.agent_status
      // Only show typing indicator if agent is working on this specific creative
      if (agentCreativeId && String(agentCreativeId) !== String(this.creativeId)) {
        return
      }
      if (status === 'thinking' || status === 'streaming') {
        this.typingUsers[id] = name
        if (!this.activeAgentTasks) this.activeAgentTasks = {}
        if (task_id) this.activeAgentTasks[id] = task_id
        // Safety timeout: auto-remove if no heartbeat within AGENT_STATUS_TIMEOUT
        if (!this.agentStatusTimers) this.agentStatusTimers = {}
        if (this.agentStatusTimers[id]) clearTimeout(this.agentStatusTimers[id])
        this.agentStatusTimers[id] = setTimeout(() => {
          delete this.typingUsers[id]
          delete this.agentStatusTimers[id]
          delete this.activeAgentTasks?.[id]
          this.syncGlobalAgentTasks()
          this.renderTypingIndicator()
        }, AGENT_STATUS_TIMEOUT)
      } else {
        delete this.typingUsers[id]
        delete this.activeAgentTasks?.[id]
        if (this.agentStatusTimers?.[id]) {
          clearTimeout(this.agentStatusTimers[id])
          delete this.agentStatusTimers[id]
        }
      }
      this.syncGlobalAgentTasks()
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

      // AI agents are draggable to topic tabs
      if (user.ai_user) {
        wrapper.draggable = true
        wrapper.classList.add('ai-agent-draggable')
        wrapper.dataset.agentId = user.id
        wrapper.dataset.agentName = user.name
        wrapper.dataset.agentAvatarUrl = user.avatar_url

        // HTML5 DnD (desktop)
        wrapper.addEventListener('dragstart', (e) => {
          e.dataTransfer.setData('application/x-agent-drop', JSON.stringify({
            id: user.id,
            name: user.name,
            avatar_url: user.avatar_url
          }))
          e.dataTransfer.effectAllowed = 'copy'
          wrapper.classList.add('dragging')
        })
        wrapper.addEventListener('dragend', () => {
          wrapper.classList.remove('dragging')
        })

        // Touch drag (mobile)
        this._addAgentTouchDrag(wrapper, user)
      }

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

    if (this.canShare) {
      const addBtn = document.createElement('button')
      addBtn.className = 'add-participant-btn'
      addBtn.textContent = '+'
      addBtn.title = this.element.dataset.addParticipantText || 'Add user'
      addBtn.dataset.action = 'click->share-modal#open'
      addBtn.dataset.shareModalUrlParam = `/creatives/${this.creativeId}/creative_shares`
      this.participantsTarget.appendChild(addBtn)
    }

    this.updateReadReceiptPresence(presentIds)
  }


  renderTypingIndicator() {
    if (!this.hasTypingIndicatorTarget) return
    this.typingIndicatorTarget.innerHTML = ''

    if (this.manualTypingMessage) {
      const message = document.createElement('span')
      message.textContent = this.manualTypingMessage
      this.typingIndicatorTarget.style.opacity = '1'
      this.typingIndicatorTarget.appendChild(message)
      return
    }

    const ids = Object.keys(this.typingUsers)
    if (ids.length === 0) {
      this.typingIndicatorTarget.style.opacity = '0'
      this.typingIndicatorTarget.style.pointerEvents = 'auto'
      return
    }

    this.typingIndicatorTarget.style.opacity = '1'

    // Add stop button first (before avatars/names) for active agent tasks
    const hasActiveTask = ids.some((id) => this.activeAgentTasks?.[id])
    if (hasActiveTask) {
      const stopBtn = document.createElement('button')
      stopBtn.type = 'button'
      stopBtn.className = 'agent-stop-btn'
      const stopLabel = this.typingIndicatorTarget.dataset.stopAgentText || 'Stop'
      stopBtn.innerHTML = `<span class="agent-stop-icon">\u25A0</span> ${stopLabel}`
      stopBtn.title = stopLabel
      stopBtn.addEventListener('click', () => {
        ids.forEach((id) => {
          const taskId = this.activeAgentTasks?.[id]
          if (taskId) this.cancelAgentTask(taskId, id)
        })
      })
      this.typingIndicatorTarget.appendChild(stopBtn)
    }

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

  syncGlobalAgentTasks() {
    window._activeAgentTasks = this.activeAgentTasks ? { ...this.activeAgentTasks } : {}
    window.dispatchEvent(new CustomEvent('agent-tasks-changed', { detail: window._activeAgentTasks }))
  }

  cancelAllAgentTasks() {
    const ids = Object.keys(this.activeAgentTasks || {})
    if (ids.length === 0) return false
    ids.forEach((id) => {
      const taskId = this.activeAgentTasks[id]
      if (taskId) this.cancelAgentTask(taskId, id)
    })
    return true
  }

  cancelAgentTask(taskId, agentId) {
    csrfFetch(`/tasks/${taskId}/cancel`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
      .then((response) => {
        if (response.ok) {
          delete this.typingUsers[agentId]
          delete this.activeAgentTasks?.[agentId]
          if (this.agentStatusTimers?.[agentId]) {
            clearTimeout(this.agentStatusTimers[agentId])
            delete this.agentStatusTimers[agentId]
          }
          this.syncGlobalAgentTasks()
          this.renderTypingIndicator()
        }
      })
      .catch((err) => console.warn('[presence] cancel agent task failed:', err))
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
    this.element.style.maxHeight = ''
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
    this.element.style.maxHeight = inset > 0
      ? `${window.innerHeight - inset}px`
      : ''
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

  // ── Agent touch drag-and-drop (mobile) ─────────────────

  _addAgentTouchDrag(wrapper, user) {
    if (!('ontouchstart' in window)) return

    const handler = new TouchDragHandler({
      container: wrapper,
      singleElement: true,
      dropTargetSelector: '.topic-tag.topic-drop-target, .topic-creation-container',
      draggingClass: 'dragging',

      proxyContent: () =>
        `<span class="touch-drag-proxy-badge">${user.name}</span>`,

      onDrop: (targetEl) => {
        const agentData = { id: user.id, name: user.name, avatar_url: user.avatar_url }
        const topicsCtrl = this.application.getControllerForElementAndIdentifier(
          this.element, 'comments--topics'
        )
        if (!topicsCtrl) return

        if (targetEl.closest('.topic-creation-container')) {
          topicsCtrl.createTopicWithAgent(agentData)
        } else {
          const topicTag = targetEl.closest('.topic-tag.topic-drop-target')
          if (topicTag?.dataset.id) {
            topicsCtrl.setTopicPrimaryAgent(topicTag.dataset.id, agentData)
          }
        }
      }
    })

    // Store for cleanup if needed
    if (!this._agentTouchDragHandlers) this._agentTouchDragHandlers = []
    this._agentTouchDragHandlers.push(handler)
  }
}
