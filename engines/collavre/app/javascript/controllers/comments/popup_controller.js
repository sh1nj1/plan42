import { handleCreativeChatClick } from './creative_chat_navigation'
import { Controller } from '@hotwired/stimulus'
import chatHistory from '../../lib/chat_history'
import chatDrafts from '../../lib/chat_drafts'
import PopupFullscreen from './popup_fullscreen'

const SIZE_STORAGE_KEY = 'commentsPopupSize'
const CREATIVE_CLICK_EVENT = 'creative-comments-click'
const CREATIVE_DESTROYED_EVENT = 'creative-destroyed'
const LONG_PRESS_MS = 500

export default class extends Controller {
  static targets = [
    'title',
    'list',
    'form',
    'closeButton',
    'closeIcon',
    'expandDockedIcon',
    'leftHandle',
    'rightHandle',
    'fullscreenButton',
    'fullscreenIcon',
    'exitFullscreenIcon',
    'navBack',
    'navContainer',
    'navDropdown',
    'header',
    'typingIndicator',
  ]

  initialize() {
    this.fullscreen = new PopupFullscreen({
      element: this.element,
      isMobile: () => this.isMobile(),
      isDocked: () => this.isDocked(),
      syncUi: entering => this._syncFullscreenUI(entering),
      syncDockedUi: () => this.syncDockedUI(),
      getListController: () => this.listController,
      getTopicsController: () => this.topicsController,
      getCurrentButton: () => this.currentButton,
      setCurrentButton: button => { this.currentButton = button },
    })
  }

  connect() {
    this.currentButton = null
    this.reservedHeight = 0
    this.resizing = null
    this.touchStartY = null
    this.openFromUrlObserver = null
    this.openFromUrlTimeout = null
    this.dockedOpenTimeout = null
    this.openGeneration = 0
    this._wakeLockRequest = null
    this.handleCreativeClick = this.handleCreativeClick.bind(this)
    this.handleCreativeDestroyed = this.handleCreativeDestroyed.bind(this)
    this.handleEditingStart = this.handleEditingStart.bind(this)
    this.handleEditingStop = this.handleEditingStop.bind(this)
    this.handleTouchStart = this.handleTouchStart.bind(this)
    this.handleTouchEnd = this.handleTouchEnd.bind(this)
    this.handleResizeMove = this.handleResizeMove.bind(this)
    this.handleResizeStop = this.handleResizeStop.bind(this)
    this.handleCloseButtonTouchStart = this.handleCloseButtonTouchStart.bind(this)
    this.handleCloseButtonTouchEnd = this.handleCloseButtonTouchEnd.bind(this)
    this.handleOnline = this.handleOnline.bind(this)
    this.handleWindowFocus = this.handleWindowFocus.bind(this)
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this)
    this.handlePopState = this.handlePopState.bind(this)
    this.handlePopupWheel = this.handlePopupWheel.bind(this)
    this.handleChatNavKeydown = this.handleChatNavKeydown.bind(this)
    this.handleDropdownOutsideClick = this.handleDropdownOutsideClick.bind(this)
    this.handleDockedMediaChange = this.handleDockedMediaChange.bind(this)
    this._longPressTimer = null
    this._longPressTriggered = false
    this._isNavigating = false
    this._headerSwipeStartX = null
    this._headerSwipeStartY = null
    document.addEventListener(CREATIVE_CLICK_EVENT, this.handleCreativeClick)
    document.addEventListener(CREATIVE_DESTROYED_EVENT, this.handleCreativeDestroyed)
    document.addEventListener('creative-editing:start', this.handleEditingStart)
    document.addEventListener('creative-editing:stop', this.handleEditingStop)
    this.element.addEventListener('wheel', this.handlePopupWheel, { passive: false })
    window.addEventListener('online', this.handleOnline)
    window.addEventListener('focus', this.handleWindowFocus)
    document.addEventListener('visibilitychange', this.handleVisibilityChange)
    window.addEventListener('popstate', this.handlePopState)
    document.addEventListener('keydown', this.handleChatNavKeydown)
    this.dockedMediaQuery = typeof window.matchMedia === 'function'
      ? window.matchMedia('(min-width: 768px)')
      : {
          matches: window.innerWidth >= 768,
          addEventListener() {},
          removeEventListener() {},
        }
    if (this.element.dataset.docked === 'true') {
      this.dockedMediaQuery.addEventListener('change', this.handleDockedMediaChange)
    }

    // Long press on nav buttons
    this._setupNavLongPress()

    // Horizontal swipe on header for chat navigation
    if (this.hasHeaderTarget) {
      this._addSwipeListeners(this.headerTarget)
    }
    // typingIndicator may connect later — handled by targetConnected callback

    if (this.hasCloseButtonTarget) {
      this.closeButtonTarget.addEventListener('click', () => this.close())
    }
    if (this.hasLeftHandleTarget) {
      this.leftHandleTarget.addEventListener('mousedown', (event) => this.startResize(event, 'left'))
    }
    if (this.hasRightHandleTarget) {
      this.rightHandleTarget.addEventListener('mousedown', (event) => this.startResize(event, 'right'))
    }

    if (this.isMobile()) {
      // Handle touch events directly on the close button to resolve issues on mobile where layout shifts (e.g., keyboard dismissal) cause click events to be lost or delayed.
      this.element.addEventListener('touchstart', this.handleTouchStart)
      this.element.addEventListener('touchend', this.handleTouchEnd)
      if (this.hasCloseButtonTarget) {
        this.closeButtonTarget.addEventListener('touchstart', this.handleCloseButtonTouchStart, { passive: false })
        this.closeButtonTarget.addEventListener('touchend', this.handleCloseButtonTouchEnd)
      }
    }

    document.querySelectorAll('form[action$="/session"]').forEach((form) => {
      form.addEventListener('submit', () => {
        this.formController?.discardDraft()
        chatDrafts.clearAll()
        try {
          window.localStorage.removeItem(SIZE_STORAGE_KEY)
        } catch {
          // Storage can be unavailable on restricted origins; logout must continue.
        }
      })
    })

    if (this.element.dataset.autoFullscreen === 'true') {
      // Auto-fullscreen: open popup for creative then enter fullscreen
      delete this.element.dataset.autoFullscreen
      // Set previous URL to creative page (not the fullscreen URL)
      const creativeId = this.element.dataset.creativeId
      if (creativeId) {
        this._previousUrl = `/creatives/${creativeId}`
      }
      requestAnimationFrame(() => {
        this.openForCreative()
        this._enterFullscreenImmediate()
      })
    } else if (this.isFullscreen()) {
      // Sync UI for initial fullscreen state (legacy fullscreen page)
      this._syncFullscreenUI(true)
      // Defer to ensure all sibling controllers are connected
      requestAnimationFrame(() => this.openForCreative())
    } else if (this.isDocked()) {
      this.enterDockedMode()
    } else {
      this.openFromUrl()
    }
  }

  disconnect() {
    this._releaseWakeLock()
    this.clearPendingOpenFromUrl()
    if (this.dockedOpenTimeout) window.clearTimeout(this.dockedOpenTimeout)
    document.removeEventListener(CREATIVE_CLICK_EVENT, this.handleCreativeClick)
    document.removeEventListener(CREATIVE_DESTROYED_EVENT, this.handleCreativeDestroyed)
    document.removeEventListener('creative-editing:start', this.handleEditingStart)
    document.removeEventListener('creative-editing:stop', this.handleEditingStop)
    this.element.removeEventListener('wheel', this.handlePopupWheel)
    window.removeEventListener('online', this.handleOnline)
    window.removeEventListener('focus', this.handleWindowFocus)
    document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    window.removeEventListener('popstate', this.handlePopState)
    document.removeEventListener('keydown', this.handleChatNavKeydown)
    this.dockedMediaQuery?.removeEventListener('change', this.handleDockedMediaChange)
    document.removeEventListener('click', this.handleDropdownOutsideClick)
    this._clearLongPressTimer()
    if (this.hasHeaderTarget) {
      this._removeSwipeListeners(this.headerTarget)
    }
    if (this.hasTypingIndicatorTarget) {
      this._removeSwipeListeners(this.typingIndicatorTarget)
    }
    window.removeEventListener('mousemove', this.handleResizeMove)
    window.removeEventListener('mouseup', this.handleResizeStop)
    if (this.isMobile()) {
      this.element.removeEventListener('touchstart', this.handleTouchStart)
      this.element.removeEventListener('touchend', this.handleTouchEnd)
      if (this.hasCloseButtonTarget) {
        this.closeButtonTarget.removeEventListener('touchstart', this.handleCloseButtonTouchStart)
        this.closeButtonTarget.removeEventListener('touchend', this.handleCloseButtonTouchEnd)
      }
    }
  }

  get listController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--list')
  }

  get formController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--form')
  }

  get presenceController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--presence')
  }

  get mentionMenuController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--mention-menu')
  }

  get topicsController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--topics')
  }

  get contextsController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--contexts')
  }

  get dropTriggerController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--drop-trigger')
  }

  handleCreativeClick(event) {
    handleCreativeChatClick(this, event.detail || {})
  }

  reloadDockedHighlight(creativeId, highlightId) {
    this.openGeneration += 1
    const listController = this.listController
    // This direct reload supersedes any full open that is still waiting for
    // topics. That open will stop at its generation check, so release the
    // suppression it installed before starting the replacement highlight load.
    if (listController) listController.suppressTopicChangeLoad = false
    const existingComment = document.getElementById(`comment_${highlightId}`)
    if (existingComment && listController?.listTarget?.contains(existingComment)) {
      listController.highlightComment(highlightId)
      return
    }

    listController?.onPopupOpened({
      creativeId,
      highlightId,
      topicId: this.topicsController?.currentTopicId,
    })
  }

  resetDockedToEmpty() {
    this.openGeneration += 1

    if (this.isFullscreen()) this._exitFullscreenState()

    if (this.dockedOpenTimeout) {
      window.clearTimeout(this.dockedOpenTimeout)
      this.dockedOpenTimeout = null
    }

    this.currentButton = null
    this.element.dataset.creativeId = ''
    this.element.dataset.canComment = 'false'
    this.element.dataset.creativeSnippet = ''
    this.titleTarget.textContent = this.element.dataset.defaultTitle || ''
    this._clearChatActiveRow()
    this._hideNavDropdown()

    if (this.listController) this.listController.creativeId = null
    this.closeChildControllers()
    this.formController?.setCommentPermission(false)
    this.element.querySelector('#comment-topics')?.replaceChildren()
    if (this.hasListTarget) {
      this.listTarget.classList.add('docked-empty')
      this.listTarget.textContent = this.element.dataset.dockedEmptyText || ''
    }
    this.showPopup()
    this.dispatchPopupClosed()
  }

  handleCreativeDestroyed(event) {
    const destroyedIds = event.detail?.creativeIds || []

    // Remove destroyed creatives from navigation history
    destroyedIds.forEach(id => chatHistory.remove(id))
    this._updateNavButtons()

    if (this.element.style.display !== 'flex') return
    if (destroyedIds.includes(this.element.dataset.creativeId)) {
      if (this.isDocked() && !this.isFullscreen()) {
        this.resetDockedToEmpty()
      } else {
        this.close()
      }
    }
  }

  handleEditingStart() {
    if (this.element.style.display === 'flex' && !this.isFullscreen()) {
      this.element.classList.add('editor-behind')
    }
  }

  handleEditingStop() {
    this.element.classList.remove('editor-behind')
  }

  async open(button, { creativeId, highlightId } = {}) {
    const openGeneration = ++this.openGeneration
    if (this.hasListTarget) this.listTarget.classList.remove('docked-empty')
    this.currentButton = button
    const resolvedCreativeId = creativeId || button?.dataset.creativeId
    const canComment = button.dataset.canComment === 'true'
    const snippet = button.dataset.creativeSnippet || ''

    this.element.dataset.creativeId = resolvedCreativeId || ''
    this.element.dataset.canComment = canComment ? 'true' : 'false'
    this.element.dataset.autoFocusOnOpen = button?.dataset.autoFocusOnOpen || 'true'
    this.titleTarget.textContent = snippet

    this._markChatActiveRow(resolvedCreativeId)

    this.prepareSize()

    this.showPopup()
    this.updatePosition()

    const opened = await this.notifyChildControllers({
      creativeId: resolvedCreativeId,
      canComment,
      highlightId,
      openGeneration,
    })
    if (!opened) return

    // Track in chat navigation history (skip if navigating via back/forward)
    if (!this._isNavigating) {
      chatHistory.push({ creativeId: resolvedCreativeId, snippet, canComment })
    }
    this._updateNavButtons()

    // Dispatch event for integrations (e.g., Slack badge)
    this.element.dispatchEvent(new CustomEvent('comments-popup:opened', {
      bubbles: true,
      detail: {
        creativeId: resolvedCreativeId,
        badgeContainer: this.element.querySelector('[data-integration-badges]')
      }
    }))
  }

  async openForCreative({ highlightId } = {}) {
    const openGeneration = ++this.openGeneration
    if (this.hasListTarget) this.listTarget.classList.remove('docked-empty')
    const resolvedCreativeId = this.element.dataset.creativeId
    const canComment = this.element.dataset.canComment === 'true'
    const snippet = this.element.dataset.creativeSnippet || ''

    this.currentButton = null
    this.element.dataset.creativeId = resolvedCreativeId || ''
    this.element.dataset.canComment = canComment ? 'true' : 'false'
    this.element.dataset.autoFocusOnOpen = 'true'
    this.titleTarget.textContent = snippet

    this._markChatActiveRow(resolvedCreativeId)

    this.showPopup()

    const opened = await this.notifyChildControllers({
      creativeId: resolvedCreativeId,
      canComment,
      highlightId,
      openGeneration,
    })
    if (!opened) return

    // Track in chat navigation history
    if (!this._isNavigating) {
      chatHistory.push({ creativeId: resolvedCreativeId, snippet, canComment })
    }
    this._updateNavButtons()

    // Dispatch event for integrations (e.g., Slack badge)
    this.element.dispatchEvent(new CustomEvent('comments-popup:opened', {
      bubbles: true,
      detail: {
        creativeId: resolvedCreativeId,
        badgeContainer: this.element.querySelector('[data-integration-badges]')
      }
    }))
  }

  async notifyChildControllers({ creativeId, canComment, highlightId, openGeneration }) {
    this.topicsController?.clearOverrideTopicId()
    // Drop the previous creative's topic selection from the form controller
    // synchronously, BEFORE topics loadTopics() dispatches `comments--topics:change`
    // (which repopulates these via handleTopicChange). Doing it later — e.g. in
    // formController.onPopupOpened, which runs after the topics await — would
    // erase the topic that restoreSelection() just restored from the server.
    if (this.formController) {
      this.formController.onChatWillOpen?.({ creativeId })
      this.formController.currentTopicId = ''
      this.formController._mainTopicId = null
    }
    // Switching creatives reuses the context controller. Clear its previous
    // creative synchronously so a slow topic load cannot leave stale context
    // controls interactive under the new creative title.
    this.contextsController?.onChatWillOpen?.({ creativeId })
    // Participant rows can insert mentions, so clear them before the same topic
    // await rather than leaving the previous creative's popup interactive.
    this.presenceController?.onChatWillOpen?.({ creativeId })
    // Pre-set creativeId on list controller BEFORE loading topics.
    // Topics loading triggers a change event that list controller handles.
    // Without this, list controller still holds the previous creative's ID
    // and would fetch comments for the wrong creative (race condition).
    //
    // Also suppress topic-change-triggered loads during topic initialization.
    // Without this, the topic change event fires loadInitialComments() before
    // onPopupOpened sets highlightAfterLoad, causing a race where the non-highlight
    // load can overwrite the deep-link highlight load.
    const suppressedListController = this.listController
    if (suppressedListController) {
      suppressedListController.creativeId = creativeId
      suppressedListController.suppressTopicChangeLoad = true
    }

    // Load topics first to establish context
    try {
      if (this.topicsController) {
        await this.topicsController.onPopupOpened({ creativeId })
      }
    } catch (error) {
      if (openGeneration === this.openGeneration && suppressedListController) {
        suppressedListController.suppressTopicChangeLoad = false
      }
      throw error
    }

    if (openGeneration !== this.openGeneration) return false

    if (suppressedListController) {
      suppressedListController.suppressTopicChangeLoad = false
    }

    if (this.formController) {
      this.formController.onPopupOpened({ creativeId, canComment })
    }
    if (this.listController) {
      const topicId = this.topicsController ? this.topicsController.currentTopicId : undefined
      this.listController.onPopupOpened({ creativeId, highlightId, topicId })
    }
    if (this.presenceController) {
      this.presenceController.onPopupOpened({ creativeId })
    }
    if (this.mentionMenuController) {
      this.mentionMenuController.onPopupOpened({ creativeId })
    }
    if (this.contextsController) {
      this.contextsController.onPopupOpened({ creativeId })
    }
    if (this.dropTriggerController) {
      this.dropTriggerController.onPopupOpened({ creativeId })
    }
    return true
  }

  close() {
    if (this.isDocked() && !this.isFullscreen()) {
      this.toggleDocked()
      return
    }

    this.openGeneration += 1

    this.closeChildControllers()
    this.dispatchPopupClosed()

    this._exitFullscreenState()

    this._clearChatActiveRow()
    this._hideNavDropdown()
    this._releaseWakeLock()

    this.element.style.display = 'none'
    this.element.classList.remove('open', 'editor-behind')
    this.element.style.width = ''
    this.element.style.height = ''
    this.element.style.left = ''
    this.element.style.right = ''
    this.element.style.top = ''
    this.element.style.bottom = ''
    this.element.style.position = ''
    delete this.element.dataset.resized
  }

  _exitFullscreenState() {
    this.fullscreen.exitState()
  }

  closeChildControllers() {
    this.presenceController?.onPopupClosed()
    this.formController?.onPopupClosed()
    this.listController?.onPopupClosed()
    this.mentionMenuController?.onPopupClosed()
    this.topicsController?.onPopupClosed()
    this.contextsController?.onPopupClosed()
    this.dropTriggerController?.onPopupClosed()
  }

  dispatchPopupClosed() {
    this.element.dispatchEvent(new CustomEvent('comments-popup:closed', {
      bubbles: true,
      detail: {
        badgeContainer: this.element.querySelector('[data-integration-badges]')
      }
    }))
  }

  prepareSize() {
    if (this.isDocked()) return

    const stored = window.localStorage.getItem(SIZE_STORAGE_KEY)
    if (!stored) return
    try {
      const parsed = JSON.parse(stored)
      if (parsed.width) this.element.style.width = parsed.width
      if (parsed.height) {
        this.element.style.height = parsed.height
      }
    } catch (error) {
      console.warn('Failed to parse comments popup size', error)
    }
  }



  showPopup() {
    this.element.style.display = 'flex'
    if (this.isDocked()) {
      this.element.classList.add('docked')
      this.syncDockedUI()
    } else if (this.isMobile()) {
      this.element.classList.add('open')
    }
    this._syncWakeLock()
  }

  isFullscreen() {
    return this.element.dataset.fullscreen === 'true'
  }

  get _savedStyles() {
    return this.fullscreen?.savedStyles
  }

  set _savedStyles(value) {
    if (this.fullscreen) this.fullscreen.savedStyles = value
  }

  get _previousUrl() {
    return this.fullscreen?.previousUrl
  }

  set _previousUrl(value) {
    if (this.fullscreen) this.fullscreen.previousUrl = value
  }

  isMobile() {
    return window.innerWidth <= 600
  }

  isDocked() {
    return this.element.dataset.docked === 'true' && this.dockedMediaQuery?.matches === true
  }

  enterDockedMode() {
    const el = this.element
    if (this.dockedOpenTimeout) window.clearTimeout(this.dockedOpenTimeout)
    el.classList.add('docked')
    el.classList.remove('open')
    el.style.position = ''
    el.style.top = ''
    el.style.left = ''
    el.style.right = ''
    el.style.bottom = ''
    el.style.width = ''
    el.style.height = ''
    delete el.dataset.resized
    this.showPopup()

    if (el.dataset.creativeId) {
      requestAnimationFrame(() => {
        this.dockedOpenTimeout = window.setTimeout(() => {
          this.dockedOpenTimeout = null
          if (!this.element.isConnected || !this.isDocked()) return

          this.openForCreative({ highlightId: this.commentIdFromUrl() })
        }, 0)
      })
    } else if (this.hasListTarget) {
      this.listTarget.classList.add('docked-empty')
      this.listTarget.textContent = el.dataset.dockedEmptyText || ''
    }
  }

  handleDockedMediaChange(event) {
    if (event.matches) {
      this.enterDockedMode()
    } else {
      this.element.classList.remove('docked', 'docked-collapsed')
      this.syncDockedUI()
      this.close()
    }
  }

  toggleDocked() {
    if (!this.isDocked()) return

    if (this.element.classList.contains('docked-collapsed')) {
      this.expandDocked()
      return
    }

    this.element.classList.add('docked-collapsed')
    this.syncDockedUI()
    this._syncWakeLock()
  }

  expandDocked({ scrollToBottom = true } = {}) {
    if (!this.isDocked()) return
    if (!this.element.classList.contains('docked-collapsed')) return

    this.element.classList.remove('docked-collapsed')
    this.syncDockedUI()
    this._syncWakeLock()
    if (scrollToBottom) requestAnimationFrame(() => this.listController?.scrollToBottom())
  }

  syncDockedUI() {
    if (!this.hasCloseButtonTarget) return

    if (!this.isDocked()) {
      const label = this.element.dataset.closeLabel || ''
      this.closeIconTarget.style.display = ''
      this.expandDockedIconTarget.style.display = 'none'
      this.closeButtonTarget.setAttribute('aria-label', label)
      this.closeButtonTarget.title = label
      return
    }

    const collapsed = this.element.classList.contains('docked-collapsed')
    const label = collapsed
      ? (this.element.dataset.expandDockedLabel || '')
      : (this.element.dataset.collapseDockedLabel || '')
    this.closeIconTarget.style.display = collapsed ? 'none' : ''
    this.expandDockedIconTarget.style.display = collapsed ? '' : 'none'
    this.closeButtonTarget.setAttribute('aria-label', label)
    this.closeButtonTarget.title = label
  }

  updatePosition() {
    if (this.isDocked() || this.isFullscreen() || !this.currentButton || this.isMobile() || this.element.dataset.resized === 'true') return
    const rect = this.currentButton.getBoundingClientRect()
    const popupWidth = this.element.offsetWidth
    const popupHeight = this.element.offsetHeight
    const gap = 8

    let top = rect.bottom + 4
    const bottom = top + popupHeight
    if (bottom > window.innerHeight) {
      top = Math.max(4, window.innerHeight - popupHeight - 4)
    }
    this.element.style.top = `${top}px`

    // If there's enough space to the right of the button, align popup to the right
    // so the creative list on the left remains visible
    const spaceRight = window.innerWidth - rect.right - gap
    if (spaceRight >= popupWidth) {
      this.element.style.left = `${rect.right + gap}px`
      this.element.style.right = ''
    } else {
      this.element.style.right = `${window.innerWidth - rect.right + 24}px`
      this.element.style.left = ''
    }
  }

  startResize(event, direction) {
    if (this.isDocked()) return

    event.preventDefault()
    const rect = this.element.getBoundingClientRect()
    this.resizeStartX = event.clientX
    this.resizeStartY = event.clientY
    this.startWidth = rect.width
    this.startHeight = rect.height
    this.startLeft = rect.left
    this.startTop = rect.top
    this.startBottom = this.startTop + this.startHeight
    // this.reservedHeight = this.computeReservedHeight()
    this.element.style.left = `${this.startLeft}px`
    this.element.style.right = ''
    this.resizing = direction
    this.element.dataset.resized = 'true'
    window.addEventListener('mousemove', this.handleResizeMove)
    window.addEventListener('mouseup', this.handleResizeStop)
  }

  handleResizeMove(event) {
    if (!this.resizing) return
    const dx = event.clientX - this.resizeStartX
    const dy = event.clientY - this.resizeStartY

    let newWidth = this.startWidth
    let newLeft = this.startLeft

    if (this.resizing === 'left') {
      newWidth = Math.max(200, this.startWidth - dx)
      newLeft = this.startLeft + dx
      if (newWidth === 200) newLeft = this.startLeft + (this.startWidth - 200)
      this.element.style.left = `${newLeft}px`
    } else if (this.resizing === 'right') {
      newWidth = Math.max(200, this.startWidth + dx)
    }

    this.element.style.width = `${newWidth}px`

    let newTop = this.startTop + dy
    let newHeight = this.startBottom - newTop
    if (newHeight < 200) {
      newHeight = 200
      newTop = this.startBottom - 200
    }

    this.element.style.top = `${newTop}px`
    this.element.style.height = `${newHeight}px`
    // this.listController?.setListHeight(newHeight - this.reservedHeight)
  }

  handleResizeStop() {
    if (this.resizing) {
      window.localStorage.setItem(
        SIZE_STORAGE_KEY,
        JSON.stringify({ width: this.element.style.width, height: this.element.style.height })
      )
    }
    this.resizing = null
    window.removeEventListener('mousemove', this.handleResizeMove)
    window.removeEventListener('mouseup', this.handleResizeStop)
  }

  handleTouchStart(event) {
    if (!this.isMobile()) return
    // Ignore swipe when share modal is open
    const shareModal = document.getElementById("share-creative-modal")
    if (shareModal && shareModal.style.display === "flex") {
      this.touchStartY = null
      return
    }
    if (event.target.closest('#comments-list, .chat-nav-dropdown, .common-popup')) {
      this.touchStartY = null
    } else {
      this.touchStartY = event.touches[0].clientY
    }
  }

  handleTouchEnd(event) {
    if (this.touchStartY === null) return
    const diffY = event.changedTouches[0].clientY - this.touchStartY
    if (diffY > 50) {
      this.close()
    }
    this.touchStartY = null
  }

  handleCloseButtonTouchStart(event) {
    event.preventDefault()
  }

  handleCloseButtonTouchEnd(event) {
    event.preventDefault()
    this.close()
  }

  handleOnline() {
    if (this.element.style.display === 'flex') {
      this.listController?.loadInitialComments()
    }
  }

  handleWindowFocus() {
    if (this.element.style.display === 'flex') {
      this.listController?.loadInitialComments()
    }
  }

  handleVisibilityChange() {
    if (!document.hidden && this.element.style.display === 'flex') {
      this.listController?.loadInitialComments()
      // Re-acquire wake lock — released automatically when tab loses visibility
      this._syncWakeLock()
    }
  }

  // Prevent wheel events on the popup from scrolling the background creative list
  handlePopupWheel(event) {
    if (this.isFullscreen()) return // fullscreen already blocks body scroll via CSS

    // Don't interfere with scroll inside overlays (e.g., share modal)
    if (event.target.closest('#share-creative-modal')) return

    // Allow scroll inside any independently scrollable child element.
    // Walk up from the event target to find any element (other than the main
    // comments list, which is handled below) that can scroll on its own.
    const { element: scrollableChild, axis } = this._findScrollableAncestor(event.target, event)
    if (scrollableChild) {
      if (axis === 'x') {
        // Horizontal scroll — check left/right boundaries
        const { scrollLeft, scrollWidth, clientWidth } = scrollableChild
        const isScrollingRight = event.deltaX > 0
        const atLeft = scrollLeft <= 0
        const atRight = scrollLeft + clientWidth >= scrollWidth - 1

        if ((isScrollingRight && atRight) || (!isScrollingRight && atLeft)) {
          event.preventDefault()
        }
      } else {
        // Vertical scroll — check top/bottom boundaries
        const { scrollTop, scrollHeight, clientHeight } = scrollableChild
        const isScrollingDown = event.deltaY > 0
        const atTop = scrollTop <= 0
        const atBottom = scrollTop + clientHeight >= scrollHeight - 1

        if ((isScrollingDown && atBottom) || (!isScrollingDown && atTop)) {
          event.preventDefault()
        }
      }
      return
    }

    if (!this.hasListTarget) {
      event.preventDefault()
      return
    }

    const { scrollTop, scrollHeight, clientHeight } = this.listTarget
    const isScrollingDown = event.deltaY > 0
    const atTop = scrollTop <= 0
    const atBottom = scrollTop + clientHeight >= scrollHeight - 1

    // If the scrollable area has no overflow, or we're at the boundary, block propagation
    if (scrollHeight <= clientHeight) {
      event.preventDefault()
      return
    }

    // At boundaries, prevent the event from reaching the background
    if ((isScrollingDown && atBottom) || (!isScrollingDown && atTop)) {
      event.preventDefault()
    }
  }

  // Enter fullscreen immediately without animation (for auto-fullscreen on page load)
  _enterFullscreenImmediate() {
    this.fullscreen.enterImmediate()
  }

  toggleFullscreen() {
    this.fullscreen.toggle()
  }

  handlePopState(event) {
    this.fullscreen.handlePopState(event)
  }

  _syncFullscreenUI(entering) {
    if (this.hasFullscreenIconTarget) {
      this.fullscreenIconTarget.style.display = entering ? 'none' : ''
    }
    if (this.hasExitFullscreenIconTarget) {
      this.exitFullscreenIconTarget.style.display = entering ? '' : 'none'
    }
    if (this.hasLeftHandleTarget) {
      this.leftHandleTarget.style.display = entering || this.isDocked() ? 'none' : ''
    }
    if (this.hasRightHandleTarget) {
      this.rightHandleTarget.style.display = entering || this.isDocked() ? 'none' : ''
    }
    if (this.hasCloseButtonTarget) {
      this.closeButtonTarget.style.display = entering ? 'none' : ''
    }
    if (this.hasFullscreenButtonTarget) {
      const label = entering
        ? (this.element.dataset.exitFullscreenLabel || 'Exit full screen')
        : (this.element.dataset.fullscreenLabel || 'Full screen')
      this.fullscreenButtonTarget.setAttribute('aria-label', label)
    }
    if (!entering) this.syncDockedUI()
  }

  commentIdFromUrl() {
    const params = new URLSearchParams(window.location.search)
    let commentId = params.get('comment_id')
    if (!commentId) {
      const pathCommentMatch = window.location.pathname.match(/\/creatives\/\d+\/comments\/(\d+)/)
      if (pathCommentMatch) {
        commentId = pathCommentMatch[1]
      }
    }
    if (!commentId) {
      const hashMatch = window.location.hash.match(/comment_(\d+)/)
      if (hashMatch) {
        commentId = hashMatch[1]
      }
    }

    return commentId || undefined
  }

  openFromUrl() {
    const params = new URLSearchParams(window.location.search)
    const openComments = params.get('open_comments') === 'true'
    const commentId = this.commentIdFromUrl()

    let creativeId = params.get('id')
    if (!creativeId) {
      const pathCreativeMatch = window.location.pathname.match(/\/creatives\/(\d+)/)
      if (pathCreativeMatch) {
        creativeId = pathCreativeMatch[1]
      }
    }

    // Need either open_comments flag or comment_id, plus creativeId
    if ((!commentId && !openComments) || !creativeId) return
    const selector = `[name="show-comments-btn"][data-creative-id="${creativeId}"]`
    const tryOpenWithButton = () => {
      const button = document.querySelector(selector)
      if (!button) return false
      this.clearPendingOpenFromUrl()
      this.open(button, { highlightId: commentId || undefined })
      return true
    }

    if (tryOpenWithButton()) return

    if (this.openFromUrlObserver) this.openFromUrlObserver.disconnect()
    this.openFromUrlObserver = new MutationObserver(() => {
      if (tryOpenWithButton()) {
        this.clearPendingOpenFromUrl()
      }
    })
    this.openFromUrlObserver.observe(document.body, { childList: true, subtree: true })

    if (this.openFromUrlTimeout) window.clearTimeout(this.openFromUrlTimeout)
    this.openFromUrlTimeout = window.setTimeout(() => {
      this.clearPendingOpenFromUrl()
    }, 5000)
  }

  clearPendingOpenFromUrl() {
    if (this.openFromUrlObserver) {
      this.openFromUrlObserver.disconnect()
      this.openFromUrlObserver = null
    }
    if (this.openFromUrlTimeout) {
      window.clearTimeout(this.openFromUrlTimeout)
      this.openFromUrlTimeout = null
    }
  }

  _markChatActiveRow(creativeId) {
    this._clearChatActiveRow()
    if (!creativeId) return
    const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
    if (row) row.classList.add('chat-active')
  }

  _clearChatActiveRow() {
    document.querySelectorAll('creative-tree-row.chat-active').forEach(el => {
      el.classList.remove('chat-active')
    })
  }

  // Walk up from the target element to find the nearest scrollable ancestor
  // that is NOT the main comments list (which has its own scroll handling).
  // Detects both vertical and horizontal scrollable elements.
  // Returns { element, axis } or { element: null, axis: null }.
  _findScrollableAncestor(target, event) {
    let el = target
    const listEl = this.hasListTarget ? this.listTarget : null
    const dominantAxis = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? 'x' : 'y'

    while (el && el !== this.element) {
      // Skip the main comments list — it's handled separately
      if (el === listEl) return { element: null, axis: null }

      // Cheap size checks first to avoid expensive getComputedStyle calls
      const hasOverflowY = el.scrollHeight > el.clientHeight
      const hasOverflowX = el.scrollWidth > el.clientWidth

      if (hasOverflowY || hasOverflowX) {
        const style = getComputedStyle(el)

        if (dominantAxis === 'x' && hasOverflowX) {
          const scrollableX = style.overflowX === 'auto' || style.overflowX === 'scroll'
          if (scrollableX) return { element: el, axis: 'x' }
        }

        if (dominantAxis === 'y' && hasOverflowY) {
          const scrollableY = style.overflowY === 'auto' || style.overflowY === 'scroll'
          if (scrollableY) return { element: el, axis: 'y' }
        }
      }

      el = el.parentElement
    }
    return { element: null, axis: null }
  }

  // ── Chat Navigation ───────────────────────────────────────────────

  navigateBack() {
    if (this._longPressTriggered) {
      this._longPressTriggered = false
      return
    }
    const entry = chatHistory.prev()
    if (!entry) return
    this._navigateToEntry(entry, 'back')
  }

  navigateForward() {
    const entry = chatHistory.next()
    if (!entry) return
    this._navigateToEntry(entry, 'forward')
  }

  showRecentChats(event) {
    event.preventDefault()
    const list = chatHistory.recentList().filter(entry => !entry.isCurrent)
    if (list.length === 0) return

    if (!this.hasNavDropdownTarget) return
    const dropdown = this.navDropdownTarget
    dropdown.innerHTML = ''

    list.forEach((entry, index) => {
      const item = document.createElement('div')
      item.className = 'chat-nav-dropdown-item'

      const label = document.createElement('button')
      label.type = 'button'
      label.className = 'chat-nav-dropdown-label'
      label.textContent = entry.snippet || `Creative #${entry.creativeId}`
      label.addEventListener('click', () => {
        this._hideNavDropdown()
        const target = chatHistory.goTo(entry.index)
        if (target) this._navigateToEntry(target)
      })
      item.appendChild(label)

      const removeBtn = document.createElement('button')
      removeBtn.type = 'button'
      removeBtn.className = 'chat-nav-dropdown-remove'
      removeBtn.innerHTML = '&times;'
      removeBtn.title = this._i18n('remove_from_history')
      removeBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        chatHistory.remove(entry.creativeId)
        this._updateNavButtons()
        // Re-render dropdown if still enough items
        const remaining = chatHistory.recentList().filter(e => !e.isCurrent)
        if (remaining.length > 0) {
          this.showRecentChats(new Event('contextmenu', { bubbles: true }))
        } else {
          this._hideNavDropdown()
        }
      })
      item.appendChild(removeBtn)

      dropdown.appendChild(item)
    })

    dropdown.style.display = 'block'

    // Close dropdown on outside click (deferred to avoid immediate trigger)
    requestAnimationFrame(() => {
      document.addEventListener('click', this.handleDropdownOutsideClick)
    })
  }

  handleDropdownOutsideClick(event) {
    if (this.hasNavContainerTarget && !this.navContainerTarget.contains(event.target)) {
      this._hideNavDropdown()
    }
  }

  handleChatNavKeydown(event) {
    // Only when popup is visible
    if (this.element.style.display !== 'flex') return
    if (event.altKey && event.key === 'ArrowLeft') {
      event.preventDefault()
      this.navigateBack()
    } else if (event.altKey && event.key === 'ArrowRight') {
      event.preventDefault()
      this.navigateForward()
    } else if ((event.ctrlKey || event.metaKey) && event.key === 'a') {
      // Ctrl+A / Cmd+A: select all messages — but only when not typing in an input
      const tag = document.activeElement?.tagName
      if (tag === 'TEXTAREA' || tag === 'INPUT' || document.activeElement?.isContentEditable) return
      if (!this.element.contains(document.activeElement) && document.activeElement !== document.body) return
      event.preventDefault()
      this.listController?.selectAll()
    }
  }

  async _navigateToEntry(entry, direction = 'forward') {
    this._isNavigating = true
    try {
      // Try to find the button for this creative in the tree
      const row = document.querySelector(`creative-tree-row[creative-id="${entry.creativeId}"]`)
      const button = row?.querySelector('[name="show-comments-btn"]')

      if (button) {
        await this.open(button, { creativeId: entry.creativeId })
      } else {
        // Creative not in current view — open directly via openForCreative
        this.element.dataset.creativeId = entry.creativeId
        this.element.dataset.canComment = entry.canComment ? 'true' : 'false'
        this.element.dataset.creativeSnippet = entry.snippet || ''
        await this.openForCreative()
      }
    } catch (error) {
      // Creative likely deleted (404) — remove from history and skip to next
      console.warn(`[chat-nav] Failed to open creative ${entry.creativeId}, removing from history:`, error)
      chatHistory.remove(entry.creativeId)
      this._updateNavButtons()

      if (chatHistory.canNavigate()) {
        this._isNavigating = false
        const next = direction === 'back' ? chatHistory.prev() : chatHistory.next()
        if (next) return this._navigateToEntry(next, direction)
      }
    } finally {
      this._isNavigating = false
    }
  }

  _updateNavButtons() {
    if (this.hasNavBackTarget) {
      this.navBackTarget.disabled = !chatHistory.canNavigate()
    }
  }

  _setupNavLongPress() {
    const setupBtn = (btn) => {
      if (!btn) return
      btn.addEventListener('mousedown', () => {
        this._longPressTriggered = false
        this._clearLongPressTimer()
        this._longPressTimer = setTimeout(() => {
          this._longPressTriggered = true
          this.showRecentChats(new MouseEvent('contextmenu', { bubbles: true }))
        }, LONG_PRESS_MS)
      })
      btn.addEventListener('mouseup', () => this._clearLongPressTimer())
      btn.addEventListener('mouseleave', () => this._clearLongPressTimer())
      // Touch long press
      btn.addEventListener('touchstart', () => {
        this._longPressTriggered = false
        this._clearLongPressTimer()
        this._longPressTimer = setTimeout(() => {
          this._longPressTriggered = true
          this.showRecentChats(new Event('contextmenu', { bubbles: true }))
        }, LONG_PRESS_MS)
      }, { passive: true })
      btn.addEventListener('touchend', () => this._clearLongPressTimer())
      btn.addEventListener('touchcancel', () => this._clearLongPressTimer())
    }
    if (this.hasNavBackTarget) setupBtn(this.navBackTarget)
  }

  _clearLongPressTimer() {
    if (this._longPressTimer) {
      clearTimeout(this._longPressTimer)
      this._longPressTimer = null
    }
  }

  typingIndicatorTargetConnected(element) {
    this._addSwipeListeners(element)
  }

  typingIndicatorTargetDisconnected(element) {
    this._removeSwipeListeners(element)
  }

  _addSwipeListeners(el) {
    el.addEventListener('touchstart', this.handleHeaderTouchStart, { passive: true })
    el.addEventListener('touchend', this.handleHeaderTouchEnd)
  }

  _removeSwipeListeners(el) {
    el.removeEventListener('touchstart', this.handleHeaderTouchStart)
    el.removeEventListener('touchend', this.handleHeaderTouchEnd)
  }

  handleHeaderTouchStart = (event) => {
    if (event.touches.length !== 1) return
    this._headerSwipeStartX = event.touches[0].clientX
    this._headerSwipeStartY = event.touches[0].clientY
  }

  handleHeaderTouchEnd = (event) => {
    if (this._headerSwipeStartX === null) return
    const dx = event.changedTouches[0].clientX - this._headerSwipeStartX
    const dy = event.changedTouches[0].clientY - this._headerSwipeStartY
    this._headerSwipeStartX = null
    this._headerSwipeStartY = null

    // Must be horizontal (dx > dy) and at least 40px
    if (Math.abs(dx) < 40 || Math.abs(dx) < Math.abs(dy)) return

    if (dx < 0) {
      // Swipe left → next chat
      this.navigateForward()
    } else {
      // Swipe right → previous chat
      this.navigateBack()
    }
  }

  _i18n(key) {
    const translations = {
      remove_from_history: this.element.dataset.removeFromHistoryLabel || 'Remove from history'
    }
    return translations[key] || key
  }

  _hideNavDropdown() {
    document.removeEventListener('click', this.handleDropdownOutsideClick)
    if (this.hasNavDropdownTarget) {
      this.navDropdownTarget.style.display = 'none'
      this.navDropdownTarget.innerHTML = ''
    }
  }

  // ── Screen Wake Lock ──────────────────────────────────────────────
  // Prevent the device screen from dimming/locking while the chat popup
  // is open.  The browser automatically releases the lock when the tab
  // loses visibility, so we re-acquire it in handleVisibilityChange().

  _shouldHoldWakeLock() {
    if (this.element.style.display !== 'flex') return false
    if (this.isFullscreen()) return true
    if (!this.isDocked()) return true

    return Boolean(this.element.dataset.creativeId) &&
      !this.element.classList.contains('docked-collapsed')
  }

  _syncWakeLock() {
    if (this._shouldHoldWakeLock()) {
      this._requestWakeLock()
    } else {
      this._releaseWakeLock()
    }
  }

  async _requestWakeLock() {
    if (
      !this._shouldHoldWakeLock() ||
      !('wakeLock' in navigator) ||
      this._wakeLock ||
      this._wakeLockRequest
    ) return

    let request
    try {
      request = navigator.wakeLock.request('screen')
      this._wakeLockRequest = request
      const wakeLock = await request
      if (this._wakeLockRequest !== request) {
        wakeLock.release()
        return
      }

      this._wakeLockRequest = null
      if (!this._shouldHoldWakeLock()) {
        wakeLock.release()
        return
      }

      this._wakeLock = wakeLock
      wakeLock.addEventListener('release', () => {
        if (this._wakeLock === wakeLock) this._wakeLock = null
      })
    } catch (err) {
      if (this._wakeLockRequest === request) this._wakeLockRequest = null
      // Wake lock request can fail (e.g. low battery, browser policy).
      // This is non-critical — just log and continue.
      console.debug('[chat] Wake lock request failed:', err.message)
    }
  }

  _releaseWakeLock() {
    this._wakeLockRequest = null
    const wakeLock = this._wakeLock
    this._wakeLock = null
    wakeLock?.release()
  }
}
