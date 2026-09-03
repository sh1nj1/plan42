import { Controller } from '@hotwired/stimulus'
import { createSubscription } from '../../services/cable'
import TouchDragHandler from '../../lib/touch_drag'
import csrfFetch from '../../lib/api/csrf_fetch'
import { alertDialog } from '../../lib/utils/dialog'
import PopupToggleGuard from '../../lib/popup_toggle_guard'
import { elementAnchor } from '../../lib/common_popup'

const TYPING_TIMEOUT = 3000
const AGENT_TASK_POLL_INTERVAL = 15000 // Poll active task statuses every 15s
const STREAMING_HEARTBEAT_TIMEOUT = 5000 // Transition streaming → thinking if no heartbeat
const PRESENCE_HEARTBEAT_INTERVAL = 30000
const PARTICIPANT_LIST_MODAL_ID = 'participant-list-modal'

// agent_status values that keep a task registered. thinking/streaming are the
// agent producing output; pending_approval is it paused on a tool approval,
// which is not the end of the task — treating it as idle would drop the task
// and stop the poll, so the status above could never be seen.
const LIVE_AGENT_STATUSES = new Set(['thinking', 'streaming', 'pending_approval'])

export default class extends Controller {
  static targets = ['participants', 'typingIndicator', 'textarea', 'privateCheckbox', 'channelChips', 'scrollRow',
    'addParticipantButton', 'participantListButton']

  connect() {
    this.creativeId = null
    this.participantsData = null
    this.canShare = false
    this._participantLoadVersion = 0
    this.currentPresentIds = []
    this.typingUsers = {}
    this.typingTimers = {}
    this.manualTypingMessage = null
    this.presenceSubscription = null
    this.typingTimeoutHandle = null
    this.activeAgentTasks = {} // { agentId: [taskId, ...] } - ordered, last is most recent
    this.agentStates = {} // { agentId: 'streaming' | 'thinking' }
    this.streamingHeartbeatTimers = {} // { agentId: timeoutHandle }
    this.agentTaskPollHandle = null
    this.hasPresenceConnected = false
    this.presenceHeartbeatHandle = null
    this.currentUserId = document.body.dataset.currentUserId
    this.selectedTopicId = null
    this.mainTopicId = null
    this.renderedAllTopicIds = null
    this.renderedAllIncludesLegacy = false

    this.handleInput = this.handleInput.bind(this)
    this.handleFocus = this.handleFocus.bind(this)
    this.handleBlur = this.handleBlur.bind(this)
    this.handleTopicChange = this.handleTopicChange.bind(this)
    this.handleRenderedAllTopics = this.handleRenderedAllTopics.bind(this)
    this.handleParticipantListClose = this.handleParticipantListClose.bind(this)

    this.textareaTarget.addEventListener('input', this.handleInput)
    this.textareaTarget.addEventListener('focus', this.handleFocus)
    this.textareaTarget.addEventListener('blur', this.handleBlur)
    this.privateCheckboxTarget?.addEventListener('change', () => this.stoppedTyping())
    this.element.addEventListener('comments--topics:change', this.handleTopicChange)
    this.element.addEventListener('comments--list:rendered-all-topics', this.handleRenderedAllTopics)
    this.element.addEventListener('entity-list:close', this.handleParticipantListClose)
  }

  disconnect() {
    this._participantLoadVersion += 1
    this._closeParticipantListPopup()
    this.unsubscribe()
    this.stopAgentTaskPoll()
    this.clearAllStreamingHeartbeats()
    this.textareaTarget.removeEventListener('input', this.handleInput)
    this.textareaTarget.removeEventListener('focus', this.handleFocus)
    this.textareaTarget.removeEventListener('blur', this.handleBlur)
    this.element.removeEventListener('comments--topics:change', this.handleTopicChange)
    this.element.removeEventListener('comments--list:rendered-all-topics', this.handleRenderedAllTopics)
    this.element.removeEventListener('entity-list:close', this.handleParticipantListClose)
  }

  handleTopicChange(event) {
    const topicId = event.detail?.topicId
    const nextSelectedTopicId = topicId || null
    const nextMainTopicId = event.detail?.mainTopicId || this.mainTopicId
    const selectionChanged = String(nextSelectedTopicId || '') !== String(this.selectedTopicId || '')

    if (selectionChanged) {
      this.stoppedTyping()
      this.clearTopicIndicators()
    }

    this.selectedTopicId = nextSelectedTopicId
    this.mainTopicId = nextMainTopicId
    if (selectionChanged) {
      this.renderedAllTopicIds = null
      this.renderedAllIncludesLegacy = false
    }

    if (selectionChanged) {
      this.reportViewingTopic()
      this.requestRunningAgents()
    }

    if (topicId) {
      this.refreshChannelChips(topicId)
    } else {
      this.clearChannelChips()
    }
  }

  handleRenderedAllTopics(event) {
    const { creativeId, topicIds, includesLegacy } = event.detail || {}
    if (String(creativeId) !== String(this.creativeId) || this.selectedTopicId) return

    this.renderedAllTopicIds = Array.isArray(topicIds) ? topicIds : []
    this.renderedAllIncludesLegacy = Boolean(includesLegacy)
    this.reportViewingTopic()
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

  onChatWillOpen({ creativeId }) {
    // Navigating the OPEN popup to another creative comes through here, not through
    // onPopupClosed() — PopupController#_navigateToEntry reuses open()/openForCreative().
    // Every piece of agent state below belongs to the chat being left: the poll is keyed
    // on task ids and /tasks/active_statuses answers for any task the user can read, so a
    // carried-over id keeps a foreign task's indicator alive here, and the Stop button it
    // renders cancels a turn in a creative that is no longer on screen.
    if (this.creativeId !== undefined && String(creativeId) !== String(this.creativeId)) {
      this.unsubscribe()
      this.resetAgentActivity()
      this.resetParticipantState()
    }
    this.creativeId = creativeId
  }

  onPopupOpened({ creativeId }) {
    this.onChatWillOpen({ creativeId })
    this.renderedAllTopicIds = null
    this.renderedAllIncludesLegacy = false
    this.loadParticipants(creativeId)
    this.subscribe()
    this.renderParticipants([])
    this.renderTypingIndicator()
    // Bootstrap chips for the topic that is already active when the popup opens.
    // Without this, chips only appear after a `topics:change` event fires
    // (i.e. a topic switch) or after a webhook arrives — leaving the user
    // unable to detach existing channels until something else triggers a paint.
    this.bootstrapChannelChips()
  }

  bootstrapChannelChips() {
    const topicsCtrl = this.application.getControllerForElementAndIdentifier(
      this.element, 'comments--topics'
    )
    const topicId = topicsCtrl?.currentTopicId
    this.selectedTopicId = topicId || null
    this.mainTopicId = topicsCtrl?.mainTopicId || null
    this.reportViewingTopic()
    if (topicId) {
      this.refreshChannelChips(topicId)
    } else {
      this.clearChannelChips()
    }
  }

  // Everything that describes activity in ONE chat. Leaving that chat — closed, or
  // navigated to another creative with the popup still open — has to drop all of it
  // together: the maps the indicator renders from, the timers that write back into
  // them, and the poll that keeps them alive. Clearing the maps alone would leave the
  // interval and the heartbeat timeouts running for a chat nobody is looking at.
  resetAgentActivity() {
    this.stopAgentTaskPoll()
    this.clearAllStreamingHeartbeats()
    this.clearTypingTimers()
    this.typingUsers = {}
    this.activeAgentTasks = {}
    this.agentStates = {}
    this.syncGlobalAgentTasks()
  }

  // An agent's turns, label, state and heartbeat come down together or not at all.
  // The heartbeat is keyed by agent, so it may only go when the agent itself does —
  // a surviving turn still needs it to degrade to thinking. Three paths remove an
  // agent (idle, Stop, poll); routing them all through here is what keeps them from
  // drifting apart, which is how that heartbeat got dropped early once already.
  dropAgent(agentId) {
    delete this.activeAgentTasks[agentId]
    delete this.typingUsers[agentId]
    delete this.agentStates[agentId]
    this.clearStreamingHeartbeat(agentId)
  }

  // Ends one turn, and the agent with it once nothing is left. A missing taskId means
  // the caller can't say which turn ended, so the agent goes entirely.
  dropAgentTask(agentId, taskId) {
    const tasks = this.activeAgentTasks[agentId]
    if (!tasks) return this.dropAgent(agentId)
    if (taskId) {
      const idx = tasks.indexOf(taskId)
      if (idx !== -1) tasks.splice(idx, 1)
    }
    if (!taskId || tasks.length === 0) this.dropAgent(agentId)
  }

  onPopupClosed() {
    this.unsubscribe()
    this.creativeId = null
    this.resetParticipantState()
    this.resetAgentActivity()
    this.clearManualTypingMessage()
    this.renderParticipants([])
    this.renderTypingIndicator()
    this.element.style.bottom = ''
  }

  resetParticipantState() {
    this._participantLoadVersion += 1
    this._closeParticipantListPopup()
    this.participantsData = null
    this.currentPresentIds = []
    this.canShare = false
    this.renderParticipants([])
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
    const topicId = this.typingTopicId
    if (!topicId) return

    this.presenceSubscription.perform('typing', { topic_id: topicId })
    this.resetTypingTimeout()
  }

  stoppedTyping() {
    const topicId = this.typingTopicId
    if (this.presenceSubscription && topicId) {
      this.presenceSubscription.perform('stopped_typing', { topic_id: topicId })
    }
    if (this.typingTimeoutHandle) {
      clearTimeout(this.typingTimeoutHandle)
      this.typingTimeoutHandle = null
    }
  }

  requestRunningAgents() {
    if (!this.presenceSubscription || !this.selectedTopicId) return

    this.presenceSubscription.perform('running_agents', { topic_id: this.selectedTopicId })
  }

  loadParticipants(creativeId = this.creativeId) {
    if (!creativeId) return
    const loadVersion = ++this._participantLoadVersion
    return fetch(`/creatives/${creativeId}/comments/participants`, {
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
        if (!this._isCurrentParticipantLoad(loadVersion, creativeId)) return
        this.participantsData = data.users
        this.canShare = data.can_share
        this.formController?.setCommentPermission(data.can_comment)
        this.renderParticipants(this.currentPresentIds)
        this.renderTypingIndicator()
      })
      .catch(() => {
        if (!this._isCurrentParticipantLoad(loadVersion, creativeId)) return
        this.participantsData = []
        this.canShare = false
        this.renderParticipants([])
        this.renderTypingIndicator()
      })
  }

  _isCurrentParticipantLoad(loadVersion, creativeId) {
    return loadVersion === this._participantLoadVersion && String(creativeId) === String(this.creativeId)
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
          this.reportViewingTopic()
          this.startPresenceHeartbeat()
        },
        received: (data) => this.handlePresenceMessage(data),
      },
    )
  }

  unsubscribe() {
    this.stopPresenceHeartbeat()
    if (this.presenceSubscription) {
      this.presenceSubscription.unsubscribe()
      this.presenceSubscription = null
    }
    this.stoppedTyping()
  }

  reportViewingTopic() {
    if (!this.presenceSubscription) return

    const payload = { topic_id: this.selectedTopicId }
    if (!this.selectedTopicId && Array.isArray(this.renderedAllTopicIds)) {
      payload.rendered_topic_ids = this.renderedAllTopicIds
      if (this.renderedAllIncludesLegacy) payload.rendered_legacy_topic = true
    }
    this.presenceSubscription.perform('viewing_topic', payload)
  }

  startPresenceHeartbeat() {
    this.stopPresenceHeartbeat()
    this.presenceHeartbeatHandle = setInterval(() => {
      this.presenceSubscription?.perform('heartbeat')
    }, PRESENCE_HEARTBEAT_INTERVAL)
  }

  stopPresenceHeartbeat() {
    if (this.presenceHeartbeatHandle) {
      clearInterval(this.presenceHeartbeatHandle)
      this.presenceHeartbeatHandle = null
    }
  }

  handlePresenceMessage(data) {
    if (data.ids) {
      this.currentPresentIds = data.ids.map((id) => parseInt(id, 10))
      this.renderParticipants(this.currentPresentIds)
      this.updateReadReceiptPresence(this.currentPresentIds)
    }
    if (data.typing) {
      const { id, name, topic_id: topicId } = data.typing
      if (!this.isSelectedTopic(topicId)) return

      const isNewTyper = !(id in this.typingUsers)
      // The user always wants to see their OWN typing indicator the moment it
      // appears — they just started typing. Stick-to-end (which pauses while the
      // user is scrolled back looking at badges) must not suppress that, so force
      // the scroll for the local user's first typing frame.
      const isSelf = String(id) === String(this.currentUserId)
      this.typingUsers[id] = name
      this.renderTypingIndicator({ newItem: isNewTyper, force: isNewTyper && isSelf })
      clearTimeout(this.typingTimers[id])
      this.typingTimers[id] = setTimeout(() => {
        delete this.typingUsers[id]
        delete this.typingTimers[id]
        this.renderTypingIndicator()
      }, TYPING_TIMEOUT)
    }
    if (data.stop_typing) {
      const { id, topic_id: topicId } = data.stop_typing
      if (!this.isSelectedTopic(topicId)) return

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

      if (shareChange.has_access === false) {
        document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', {
          detail: { creativeIds: [String(this.creativeId)] },
        }))
        alertDialog(this.element.dataset.noPermissionText || 'No permission')
        if (this.popupController?.isDocked()) {
          this.popupController.resetDockedToEmpty()
        } else {
          this.popupController?.close()
        }
        return
      }

      this.loadParticipants()
      return
    }
    if (data.channel_chips) {
      this.refreshChannelChips(data.channel_chips.topic_id)
    }
    if (data.agent_status) {
      const { id, name, status, task_id, topic_id: topicId, creative_id: agentCreativeId } = data.agent_status
      // Only show typing indicator if agent is working on this specific creative
      if (agentCreativeId && String(agentCreativeId) !== String(this.creativeId)) {
        return
      }
      if (!topicId) {
        // Turns are tracked per agent as an array, so a legacy idle has to match a
        // member — String() on the array only happens to work at length 1.
        const activeTaskIds = this.activeAgentTasks?.[id] || []
        const matchingLegacyIdle = status === 'idle' && task_id &&
          activeTaskIds.some((activeTaskId) => String(activeTaskId) === String(task_id))
        if (!matchingLegacyIdle) return
      } else if (!this.isSelectedTopic(topicId)) {
        return
      }

      const isNewAgent = (status === 'thinking' || status === 'streaming') && !(id in this.typingUsers)
      if (LIVE_AGENT_STATUSES.has(status)) {
        this.typingUsers[id] = name
        this.agentStates[id] = status
        if (!this.activeAgentTasks[id]) this.activeAgentTasks[id] = []
        if (task_id && !this.activeAgentTasks[id].includes(task_id)) {
          this.activeAgentTasks[id].push(task_id)
        }
        // Streaming heartbeat: transition to thinking if no update within timeout
        this.clearStreamingHeartbeat(id)
        if (status === 'streaming') {
          this.streamingHeartbeatTimers[id] = setTimeout(() => {
            this.agentStates[id] = 'thinking'
            delete this.streamingHeartbeatTimers[id]
            this.renderTypingIndicator()
          }, STREAMING_HEARTBEAT_TIMEOUT)
        }
        this.startAgentTaskPoll()
      } else {
        this.dropAgentTask(id, task_id)
        this.maybeStopAgentTaskPoll()
      }
      this.syncGlobalAgentTasks()
      this.renderTypingIndicator({ newItem: isNewAgent })
    }
  }

  renderParticipants(presentIds) {
    if (!this.hasParticipantsTarget || !this.participantsData) {
      if (this.hasParticipantsTarget) this.participantsTarget.innerHTML = ''
      this.updateParticipantActionButtons(presentIds)
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

    this.updateParticipantActionButtons(presentIds)
    this.updateReadReceiptPresence(presentIds)
  }

  // The add and list buttons are pinned outside the horizontally scrolling avatar
  // strip, so they stay reachable however many participants there are.
  updateParticipantActionButtons(presentIds = this.currentPresentIds) {
    if (this.hasAddParticipantButtonTarget) {
      const canOpenShare = Boolean(this.canShare && this.creativeId)
      this.addParticipantButtonTarget.style.display = canOpenShare ? '' : 'none'
      if (canOpenShare) {
        this.addParticipantButtonTarget.dataset.shareModalUrlParam = `/creatives/${this.creativeId}/creative_shares`
      } else {
        delete this.addParticipantButtonTarget.dataset.shareModalUrlParam
      }
    }
    if (this.hasParticipantListButtonTarget) {
      const hasParticipants = (this.participantsData || []).length > 0
      this.participantListButtonTarget.style.display = hasParticipants ? '' : 'none'
    }
    this.refreshOpenParticipantListPopup(presentIds)
  }

  // --- Participant list popup (mirrors the topic list button) ---
  get participantListToggleGuard() {
    this._participantListToggleGuard ||= new PopupToggleGuard()
    return this._participantListToggleGuard
  }

  prepareParticipantListToggle(event) {
    this.participantListToggleGuard.prepare(event, Boolean(this._participantListPopup()?.popup?.isOpen()))
  }

  finishParticipantListToggle(event) {
    this.participantListToggleGuard.finish(event)
  }

  cancelParticipantListToggle(event = {}) {
    this.participantListToggleGuard.cancel(event)
  }

  _participantListPopup() {
    const modal = document.getElementById(PARTICIPANT_LIST_MODAL_ID)
    return modal && this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
  }

  _closeParticipantListPopup() {
    const modal = this.element.querySelector(`#${PARTICIPANT_LIST_MODAL_ID}`)
    const popup = modal && this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
    popup?.close()
    modal?.remove()
    this._participantListToggleGuard?.cancel()
    this.setParticipantListButtonExpanded(false)
  }

  openParticipantListPopup(event) {
    if (this.participantListToggleGuard.consume()) return

    const anchor = elementAnchor(event.currentTarget)

    const openWith = (popup) => {
      popup.openForItems(
        this.participantListItems(),
        anchor,
        (item) => this.selectParticipantListItem(item),
        this.element
      )
      this.setParticipantListButtonExpanded(true)
    }

    let modal = document.getElementById(PARTICIPANT_LIST_MODAL_ID)
    if (modal) {
      const popup = this._participantListPopup()
      if (popup?.popup?.isOpen()) {
        popup.close()
        this.setParticipantListButtonExpanded(false)
      } else if (popup) {
        openWith(popup)
      }
      return
    }

    modal = document.createElement('div')
    modal.id = PARTICIPANT_LIST_MODAL_ID
    modal.className = 'common-popup'
    modal.style.display = 'none'
    modal.dataset.controller = 'entity-list'
    modal.dataset.closeLabel = this.element.dataset.closeLabel || ''
    modal.innerHTML = `
      <button type="button" class="popup-close-btn" data-entity-list-target="close">&times;</button>
      <input type="text" class="shared-input-surface" style="width:100%;margin-bottom:0.5em;"
        data-entity-list-target="input">
      <ul class="common-popup-list" data-popup-list data-entity-list-target="list"></ul>
    `
    modal.querySelector('input').placeholder =
      this.element.dataset.participantSearchPlaceholderText || 'Search users...'
    // Caged inside the chat box, like the topic list popup.
    this.element.appendChild(modal)

    requestAnimationFrame(() => {
      const popup = this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
      if (popup) openWith(popup)
      else console.error('entity-list controller not found after creation')
    })
  }

  participantListItems(presentIds = this.currentPresentIds) {
    const present = presentIds || []
    return (this.participantsData || []).map((user) => ({
      id: user.id,
      label: user.name,
      avatarUrl: user.avatar_url,
      iconKey: user.avatar_url ? null : 'user',
      // Offline reads the same here as it does on the avatar strip.
      muted: present.indexOf(user.id) === -1,
      statusLabel: present.indexOf(user.id) === -1
        ? (this.element.dataset.participantOfflineText || 'Offline')
        : (this.element.dataset.participantOnlineText || 'Online')
    }))
  }

  // Selecting mirrors clicking the avatar: it mentions the user in the composer.
  selectParticipantListItem(item) {
    const user = (this.participantsData || []).find((u) => String(u.id) === String(item.id))
    if (!user) return

    const mentionMenu = this.application.getControllerForElementAndIdentifier(this.element, 'comments--mention-menu')
    if (!mentionMenu) return

    mentionMenu.insertMention({ id: user.id, name: user.name })
    this.textareaTarget?.focus()
  }

  refreshOpenParticipantListPopup(presentIds = this.currentPresentIds) {
    const modal = this.element.querySelector(`#${PARTICIPANT_LIST_MODAL_ID}`)
    const popup = modal && this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
    if (popup?.popup?.isOpen()) popup.updateItems(this.participantListItems(presentIds))
  }

  handleParticipantListClose(event) {
    if (event.target?.id !== PARTICIPANT_LIST_MODAL_ID) return
    this.setParticipantListButtonExpanded(false)
  }

  setParticipantListButtonExpanded(expanded) {
    if (this.hasParticipantListButtonTarget) {
      this.participantListButtonTarget.setAttribute('aria-expanded', String(expanded))
    }
  }


  renderTypingIndicator({ newItem = false, force = false } = {}) {
    if (!this.hasTypingIndicatorTarget) return

    // Capture stick-to-end BEFORE mutating the DOM: only auto-scroll a newly
    // added item into view when the user was already parked at the right edge,
    // so we never yank them away from a chip they scrolled back to look at.
    // `force` overrides that guard for cases where the scroll is always wanted
    // (e.g. the local user's own typing indicator first appearing).
    const stickToEnd = force || (newItem && this.isScrollRowAtEnd())

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
    const hasActiveTask = ids.some((id) => this.activeAgentTasks[id]?.length > 0)
    if (hasActiveTask) {
      const stopBtn = document.createElement('button')
      stopBtn.type = 'button'
      stopBtn.className = 'agent-stop-btn'
      const stopLabel = this.typingIndicatorTarget.dataset.stopAgentText || 'Stop'
      stopBtn.innerHTML = `<span class="agent-stop-icon">\u25A0</span> ${stopLabel}`
      stopBtn.title = stopLabel
      stopBtn.addEventListener('click', () => {
        ids.forEach((id) => {
          const tasks = this.activeAgentTasks[id]
          if (tasks?.length > 0) {
            // Cancel the last (most recent) task
            this.cancelAgentTask(tasks[tasks.length - 1], id)
          }
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
    const text = document.createElement('span')
    const parts = ids.map((id) => {
      const name = this.typingUsers[id]
      const isAgentThinking = this.activeAgentTasks[id]?.length > 0 && this.agentStates[id] !== 'streaming'
      return isAgentThinking ? `${name} \u23F3` : `${name} ...`
    })
    text.textContent = parts.join('  ')
    this.typingIndicatorTarget.appendChild(text)

    if (stickToEnd) this.scrollRowToEnd()
  }

  // Distance (px) from the right edge still counted as "at the end". A small
  // slack absorbs sub-pixel rounding and momentum scroll so stick-to-end stays
  // engaged when the user is effectively, but not exactly, at the edge.
  static STICK_TO_END_THRESHOLD = 24

  get scrollRowElement() {
    return this.hasScrollRowTarget ? this.scrollRowTarget : null
  }

  // True when the horizontal scroll row is at (or near) its right edge — i.e.
  // the user is looking at the newest items rather than scrolled back. Returns
  // true when there is no scroll row or no overflow (nothing to yank away from).
  isScrollRowAtEnd() {
    const el = this.scrollRowElement
    if (!el) return true
    const threshold = this.constructor.STICK_TO_END_THRESHOLD
    return el.scrollLeft + el.clientWidth >= el.scrollWidth - threshold
  }

  scrollRowToEnd() {
    const el = this.scrollRowElement
    if (!el) return
    el.scrollLeft = el.scrollWidth
  }

  syncGlobalAgentTasks() {
    // no-op: stop button is now server-rendered per comment via task_id
  }

  cancelAllAgentTasks() {
    const agentIds = Object.keys(this.activeAgentTasks)
    if (agentIds.length === 0) return false
    agentIds.forEach((agentId) => {
      const tasks = this.activeAgentTasks[agentId]
      if (tasks?.length > 0) {
        this.cancelAgentTask(tasks[tasks.length - 1], agentId)
      }
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
          this.dropAgentTask(agentId, taskId)
          this.maybeStopAgentTaskPoll()
          this.syncGlobalAgentTasks()
          this.renderTypingIndicator()
        }
      })
      .catch((err) => console.warn('[presence] cancel agent task failed:', err))
  }

  clearChannelChips() {
    const target = this.hasChannelChipsTarget ? this.channelChipsTarget : null
    if (!target) return
    target.innerHTML = ''
    delete target.dataset.topicId
  }

  refreshChannelChips(topicId) {
    const target = this.hasChannelChipsTarget ? this.channelChipsTarget : null
    if (!target) return
    if (!this.creativeId) return
    if (!topicId) {
      this.clearChannelChips()
      return
    }

    // Source of truth for "what the user is looking at" is the topics
    // controller's currentTopicId, NOT the chip container's data-topic-id:
    // - On initial popup open the container is empty (no data-topic-id),
    //   so a stray broadcast for any topic in the same creative used to
    //   paint chips for the wrong topic.
    // - After the user switches topics the container's data-topic-id is
    //   stale until something repaints it, blocking legit updates.
    const topicsCtrl = this.application.getControllerForElementAndIdentifier(
      this.element, 'comments--topics'
    )
    const activeTopicId = topicsCtrl?.currentTopicId || ''
    if (String(activeTopicId) !== String(topicId)) return

    fetch(`/creatives/${this.creativeId}/topics/${topicId}/channel_chips`, {
      headers: { Accept: 'text/html' },
      credentials: 'same-origin',
    })
      .then((r) => (r.ok ? r.text() : null))
      .then((html) => {
        if (!html) return
        // A newly attached channel (e.g. a fresh PR/Preview badge) is a "new
        // item" in the scroll row. Count chips before/after and scroll the new
        // one into view, but only when the user was already at the right edge.
        const row = this.scrollRowElement
        const prevChipCount = row ? row.querySelectorAll('.channel-chip').length : 0
        const wasAtEnd = this.isScrollRowAtEnd()
        target.outerHTML = html
        const newChipCount = row ? row.querySelectorAll('.channel-chip').length : 0
        if (wasAtEnd && newChipCount > prevChipCount) this.scrollRowToEnd()
      })
      .catch((err) => console.warn('[presence] refresh channel chips failed:', err))
  }

  detachChannel(event) {
    const btn = event.currentTarget
    const id = btn.dataset.channelId
    if (!id) return
    csrfFetch(`/channels/${id}`, {
      method: 'DELETE',
      headers: { Accept: 'application/json' },
    })
      .then((response) => response.status === 204 && !response.redirected && btn.closest('.channel-chip')?.remove())
      .catch((err) => console.warn('[presence] detach channel failed:', err))
  }

  clearTypingTimers() {
    Object.values(this.typingTimers).forEach((timer) => clearTimeout(timer))
    this.typingTimers = {}
  }

  // Every indicator on screen belongs to the topic being left, and the replay that
  // follows is scoped to the new one — so the whole agent state goes, heartbeats and
  // poll included. A surviving poll would keep resurrecting the old topic's turns.
  clearTopicIndicators() {
    this.resetAgentActivity()
    this.renderTypingIndicator()
  }

  get typingTopicId() {
    return this.selectedTopicId || this.mainTopicId
  }

  isSelectedTopic(topicId) {
    return Boolean(
      this.selectedTopicId &&
      topicId &&
      String(topicId) === String(this.selectedTopicId)
    )
  }

  // ── Streaming heartbeat ─────────────────────────────────

  clearStreamingHeartbeat(agentId) {
    if (this.streamingHeartbeatTimers[agentId]) {
      clearTimeout(this.streamingHeartbeatTimers[agentId])
      delete this.streamingHeartbeatTimers[agentId]
    }
  }

  clearAllStreamingHeartbeats() {
    Object.values(this.streamingHeartbeatTimers).forEach((timer) => clearTimeout(timer))
    this.streamingHeartbeatTimers = {}
  }

  // ── Agent task status polling ──────────────────────────

  startAgentTaskPoll() {
    if (this.agentTaskPollHandle) return
    this.agentTaskPollHandle = setInterval(() => this.pollAgentTaskStatuses(), AGENT_TASK_POLL_INTERVAL)
  }

  stopAgentTaskPoll() {
    if (this.agentTaskPollHandle) {
      clearInterval(this.agentTaskPollHandle)
      this.agentTaskPollHandle = null
    }
  }

  maybeStopAgentTaskPoll() {
    if (Object.keys(this.activeAgentTasks).length === 0) this.stopAgentTaskPoll()
  }

  pollAgentTaskStatuses() {
    const allTaskIds = Object.values(this.activeAgentTasks).flat()
    if (allTaskIds.length === 0) {
      this.stopAgentTaskPoll()
      return
    }
    const requestedTaskIds = new Set(allTaskIds)

    csrfFetch(`/tasks/active_statuses?task_ids=${allTaskIds.join(',')}`, {
      headers: { Accept: 'application/json' },
    })
      .then((response) => {
        if (!response.ok) return null
        return response.json()
      })
      .then((data) => {
        if (!data) return
        // Task#active? decides what still deserves an indicator and a Stop
        // button, so the client never has to know the status vocabulary.
        const activeTaskIds = new Set(data.tasks.filter((t) => t.active).map((t) => t.id))

        // This response only speaks for the ids it was asked about. A task that
        // an agent_status message appended while the request was in flight was
        // never requested, so its absence here means nothing — keep it until a
        // poll that actually asked about it says otherwise.
        let changed = false
        Object.keys(this.activeAgentTasks).forEach((agentId) => {
          const before = this.activeAgentTasks[agentId].length
          this.activeAgentTasks[agentId] = this.activeAgentTasks[agentId].filter(
            (taskId) => activeTaskIds.has(taskId) || !requestedTaskIds.has(taskId),
          )
          if (this.activeAgentTasks[agentId].length !== before) changed = true
          if (this.activeAgentTasks[agentId].length === 0) this.dropAgent(agentId)
        })

        if (changed) this.renderTypingIndicator()
        this.maybeStopAgentTaskPoll()
      })
      .catch((err) => console.warn('[presence] poll agent task statuses failed:', err))
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
