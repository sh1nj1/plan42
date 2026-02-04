import { Controller } from '@hotwired/stimulus'

const SIZE_STORAGE_KEY = 'commentsPopupSize'
const CREATIVE_CLICK_EVENT = 'creative-comments-click'

export default class extends Controller {
  static targets = [
    'title',
    'list',
    'form',
    'closeButton',
    'leftHandle',
    'rightHandle',
    'fullscreenButton',
    'fullscreenIcon',
    'exitFullscreenIcon',
  ]

  connect() {
    this.currentButton = null
    this.reservedHeight = 0
    this.resizing = null
    this.touchStartY = null
    this.openFromUrlObserver = null
    this.openFromUrlTimeout = null
    this.handleCreativeClick = this.handleCreativeClick.bind(this)
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

    document.addEventListener(CREATIVE_CLICK_EVENT, this.handleCreativeClick)
    window.addEventListener('online', this.handleOnline)
    window.addEventListener('focus', this.handleWindowFocus)
    document.addEventListener('visibilitychange', this.handleVisibilityChange)
    window.addEventListener('popstate', this.handlePopState)

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

    document.querySelectorAll('form[action="/session"]').forEach((form) => {
      form.addEventListener('submit', () => window.localStorage.removeItem(SIZE_STORAGE_KEY))
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
    } else {
      this.openFromUrl()
    }
  }

  disconnect() {
    this.clearPendingOpenFromUrl()
    document.removeEventListener(CREATIVE_CLICK_EVENT, this.handleCreativeClick)
    window.removeEventListener('online', this.handleOnline)
    window.removeEventListener('focus', this.handleWindowFocus)
    document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    window.removeEventListener('popstate', this.handlePopState)
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

  handleCreativeClick(event) {
    const button = event.detail?.button
    const creativeId = event.detail?.creativeId
    if (!button) return
    if (
      this.element.style.display === 'flex' &&
      this.element.dataset.creativeId === (creativeId || button.dataset.creativeId)
    ) {
      this.close()
      return
    }
    this.open(button, { creativeId })
  }

  async open(button, { creativeId, highlightId } = {}) {
    this.currentButton = button
    const resolvedCreativeId = creativeId || button?.dataset.creativeId
    const canComment = button.dataset.canComment === 'true'
    const snippet = button.dataset.creativeSnippet || ''

    this.element.dataset.creativeId = resolvedCreativeId || ''
    this.element.dataset.canComment = canComment ? 'true' : 'false'
    this.titleTarget.textContent = snippet

    this.prepareSize()

    this.showPopup()
    this.updatePosition()
    document.body.classList.add('no-scroll')

    await this.notifyChildControllers({ creativeId: resolvedCreativeId, canComment, highlightId })

    // Dispatch event for integrations (e.g., Slack badge)
    this.element.dispatchEvent(new CustomEvent('comments-popup:opened', {
      bubbles: true,
      detail: {
        creativeId: resolvedCreativeId,
        badgeContainer: this.element.querySelector('[data-integration-badges]')
      }
    }))
  }

  async openForCreative() {
    const resolvedCreativeId = this.element.dataset.creativeId
    const canComment = this.element.dataset.canComment === 'true'
    const snippet = this.element.dataset.creativeSnippet || ''

    this.currentButton = null
    this.element.dataset.creativeId = resolvedCreativeId || ''
    this.element.dataset.canComment = canComment ? 'true' : 'false'
    this.titleTarget.textContent = snippet

    this.showPopup()

    await this.notifyChildControllers({ creativeId: resolvedCreativeId, canComment })

    // Dispatch event for integrations (e.g., Slack badge)
    this.element.dispatchEvent(new CustomEvent('comments-popup:opened', {
      bubbles: true,
      detail: {
        creativeId: resolvedCreativeId,
        badgeContainer: this.element.querySelector('[data-integration-badges]')
      }
    }))
  }

  async notifyChildControllers({ creativeId, canComment, highlightId }) {
    // Load topics first to establish context
    if (this.topicsController) {
      await this.topicsController.onPopupOpened({ creativeId })
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
  }

  close() {
    if (this.presenceController) {
      this.presenceController.onPopupClosed()
    }
    if (this.formController) {
      this.formController.onPopupClosed()
    }
    if (this.listController) {
      this.listController.onPopupClosed()
    }
    if (this.mentionMenuController) {
      this.mentionMenuController.onPopupClosed()
    }
    if (this.topicsController) {
      this.topicsController.onPopupClosed()
    }

    // Dispatch event for integrations
    this.element.dispatchEvent(new CustomEvent('comments-popup:closed', {
      bubbles: true,
      detail: {
        badgeContainer: this.element.querySelector('[data-integration-badges]')
      }
    }))

    this.element.style.display = 'none'
    this.element.classList.remove('open')
    this.element.style.width = ''
    this.element.style.height = ''
    this.element.style.left = ''
    this.element.style.right = ''
    this.element.style.top = ''
    this.element.style.bottom = ''
    delete this.element.dataset.resized
    document.body.classList.remove('no-scroll')
  }

  prepareSize() {
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
    if (this.isMobile()) {
      this.element.classList.add('open')
    }
  }

  isFullscreen() {
    return this.element.dataset.fullscreen === 'true'
  }

  isMobile() {
    return window.innerWidth <= 600
  }

  updatePosition() {
    if (this.isFullscreen() || !this.currentButton || this.isMobile() || this.element.dataset.resized === 'true') return
    const rect = this.currentButton.getBoundingClientRect()
    const scrollY = window.scrollY || window.pageYOffset
    let top = rect.bottom + scrollY + 4
    const bottom = top + this.element.offsetHeight
    const viewportBottom = scrollY + window.innerHeight
    if (bottom > viewportBottom) {
      top = Math.max(scrollY + 4, viewportBottom - this.element.offsetHeight - 4)
    }
    this.element.style.top = `${top}px`
    this.element.style.right = `${window.innerWidth - rect.right + 24}px`
    this.element.style.left = ''
  }

  startResize(event, direction) {
    event.preventDefault()
    const rect = this.element.getBoundingClientRect()
    this.resizeStartX = event.clientX
    this.resizeStartY = event.clientY
    this.startWidth = rect.width
    this.startHeight = rect.height
    this.startLeft = rect.left + window.scrollX
    this.startTop = rect.top + window.scrollY
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
    if (!event.target.closest('#comments-list')) {
      this.touchStartY = event.touches[0].clientY
    } else {
      this.touchStartY = null
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
    }
  }

  // Enter fullscreen immediately without animation (for auto-fullscreen on page load)
  _enterFullscreenImmediate() {
    const el = this.element
    el.style.transition = 'none'
    el.dataset.fullscreen = 'true'
    document.body.classList.add('chat-fullscreen')
    this._syncFullscreenUI(true)
    // Clear any inline position styles so CSS fullscreen rules apply
    el.style.top = ''
    el.style.left = ''
    el.style.right = ''
    el.style.bottom = ''
    el.style.width = ''
    el.style.height = ''
    el.style.position = ''
    // Force layout then restore transition
    el.offsetHeight // eslint-disable-line no-unused-expressions
    el.style.transition = ''

    // URL is already /comments/fullscreen, no pushState needed
    requestAnimationFrame(() => this.listController?.scrollToBottom())
  }

  toggleFullscreen() {
    const entering = !this.isFullscreen()
    const el = this.element

    if (entering) {
      // Save current inline styles for later restore
      this._savedStyles = {
        top: el.style.top,
        right: el.style.right,
        left: el.style.left,
        width: el.style.width,
        height: el.style.height,
      }

      // Capture current visual position
      const rect = el.getBoundingClientRect()

      // Disable transition, pin to current position as fixed
      el.style.transition = 'none'
      el.style.position = 'fixed'
      el.style.top = `${rect.top}px`
      el.style.left = `${rect.left}px`
      el.style.right = 'auto'
      el.style.width = `${rect.width}px`
      el.style.height = `${rect.height}px`

      // Force layout so the pinned position is applied
      el.offsetHeight // eslint-disable-line no-unused-expressions

      // Now enable transition and expand to fullscreen
      el.style.transition = ''
      el.dataset.fullscreen = 'true'
      document.body.classList.add('chat-fullscreen')
      this._syncFullscreenUI(true)

      // Clear inline position so CSS fullscreen rules take over
      el.style.top = '0'
      el.style.left = '0'
      el.style.right = '0'
      el.style.bottom = '0'
      el.style.width = '100%'
      el.style.height = '100%'

      // Update URL
      const creativeId = el.dataset.creativeId
      if (creativeId) {
        this._previousUrl = window.location.href
        const fullscreenPath = `/creatives/${creativeId}/comments/fullscreen`
        window.history.pushState({ fullscreen: true }, '', fullscreenPath)
      }

      // Clean up inline styles after transition ends
      const cleanup = () => {
        el.removeEventListener('transitionend', cleanup)
        el.style.top = ''
        el.style.left = ''
        el.style.right = ''
        el.style.bottom = ''
        el.style.width = ''
        el.style.height = ''
        el.style.position = ''
      }
      el.addEventListener('transitionend', cleanup, { once: true })
      // Fallback if transitionend doesn't fire
      setTimeout(cleanup, 300)

    } else {
      const savedStyles = this._savedStyles
      this._savedStyles = null

      // Calculate target position using the same logic as updatePosition()
      // so cleanup can apply it directly without calling updatePosition() (which would cause a snap)
      const creativeId = el.dataset.creativeId
      const scrollY = window.scrollY || window.pageYOffset

      // Final absolute-position values (what updatePosition would set)
      let finalTop = ''      // px string with scrollY included
      let finalRight = ''    // px string
      let finalWidth = savedStyles?.width || ''
      let finalHeight = savedStyles?.height || ''

      // Fixed-position animation targets (viewport-relative)
      let animTop, animLeft, animWidth, animHeight

      // Try to find the comment button for precise positioning
      let targetButton = this.currentButton
      if (!targetButton && creativeId) {
        const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
        targetButton = row?.querySelector('.comments-btn')
      }

      if (targetButton) {
        this.currentButton = targetButton
        const btnRect = targetButton.getBoundingClientRect()
        const rightPx = window.innerWidth - btnRect.right + 24

        animWidth = parseFloat(finalWidth) || 420
        animHeight = parseFloat(finalHeight) || 640

        // Calculate top in absolute coords (with scrollY) — same as updatePosition
        let absTop = btnRect.bottom + scrollY + 4
        const absBottom = absTop + animHeight
        const viewportBottom = scrollY + window.innerHeight
        if (absBottom > viewportBottom) {
          absTop = Math.max(scrollY + 4, viewportBottom - animHeight - 4)
        }

        // Store final absolute-position values for cleanup
        finalTop = `${absTop}px`
        finalRight = `${rightPx}px`

        // Convert to fixed coordinates for animation
        animTop = absTop - scrollY
        animLeft = window.innerWidth - rightPx - animWidth
      } else if (savedStyles && Object.values(savedStyles).some(v => v)) {
        // Fallback to saved styles
        const rightVal = parseFloat(savedStyles.right) || 32
        animWidth = parseFloat(savedStyles.width) || 420
        animHeight = parseFloat(savedStyles.height) || 640
        animLeft = savedStyles.left ? parseFloat(savedStyles.left) : (window.innerWidth - rightVal - animWidth)
        animTop = parseFloat(savedStyles.top) ? (parseFloat(savedStyles.top) - scrollY) : 100

        finalTop = savedStyles.top || ''
        finalRight = savedStyles.right || ''
      } else {
        // No reference at all: use CSS defaults
        animWidth = 420
        animHeight = 640
        animLeft = window.innerWidth - 32 - animWidth  // right: 2em
        animTop = 100
      }

      // Animated exit: pin at fullscreen position, then shrink to target
      const fsRect = el.getBoundingClientRect()

      el.style.transition = 'none'
      el.style.position = 'fixed'
      el.style.top = `${fsRect.top}px`
      el.style.left = `${fsRect.left}px`
      el.style.right = 'auto'
      el.style.bottom = 'auto'
      el.style.width = `${fsRect.width}px`
      el.style.height = `${fsRect.height}px`

      el.dataset.fullscreen = 'false'
      document.body.classList.remove('chat-fullscreen')
      this._syncFullscreenUI(false)

      // Force layout so the pinned position is applied
      el.offsetHeight // eslint-disable-line no-unused-expressions

      // Animate to target position (fixed coordinates)
      el.style.transition = ''
      el.style.top = `${animTop}px`
      el.style.left = `${animLeft}px`
      el.style.width = `${animWidth}px`
      el.style.height = `${animHeight}px`

      const cleanup = () => {
        el.removeEventListener('transitionend', cleanup)
        // Switch from fixed back to default (absolute) positioning
        // Apply the pre-calculated absolute coords directly — no updatePosition() needed
        el.style.transition = 'none'
        el.style.position = ''
        el.style.bottom = ''

        if (targetButton) {
          // Set absolute coords matching updatePosition output
          el.style.top = finalTop
          el.style.right = finalRight
          el.style.left = ''
          el.style.width = finalWidth
          el.style.height = finalHeight
        } else if (savedStyles) {
          el.style.top = ''
          el.style.left = ''
          el.style.right = ''
          el.style.width = ''
          el.style.height = ''
          Object.assign(el.style, savedStyles)
        } else {
          el.style.top = ''
          el.style.left = ''
          el.style.right = ''
          el.style.width = ''
          el.style.height = ''
        }

        // Force layout then restore transitions
        el.offsetHeight // eslint-disable-line no-unused-expressions
        el.style.transition = ''
      }
      el.addEventListener('transitionend', cleanup, { once: true })
      setTimeout(cleanup, 300)

      // Update URL — append open_comments=true so the popup stays open on refresh
      let backUrl = this._previousUrl || (creativeId ? `/creatives/${creativeId}` : null)
      if (backUrl) {
        const url = new URL(backUrl, window.location.origin)
        url.searchParams.set('open_comments', 'true')
        window.history.pushState({ fullscreen: false }, '', url.pathname + url.search)
      }
      this._previousUrl = null

      // Scroll the selected creative row into view after exiting fullscreen
      if (creativeId) {
        requestAnimationFrame(() => {
          const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
          row?.scrollIntoView({ behavior: 'smooth', block: 'center' })
        })
      }
    }

    // Scroll to bottom after layout change
    requestAnimationFrame(() => {
      this.listController?.scrollToBottom()
    })
  }

  handlePopState(event) {
    const isFs = event.state?.fullscreen === true
    if (isFs !== this.isFullscreen()) {
      const el = this.element
      // Clear any animation inline styles to avoid stale positions
      el.style.transition = 'none'
      el.style.position = ''
      el.style.top = ''
      el.style.left = ''
      el.style.right = ''
      el.style.bottom = ''
      el.style.width = ''
      el.style.height = ''

      el.dataset.fullscreen = isFs ? 'true' : 'false'
      document.body.classList.toggle('chat-fullscreen', isFs)
      this._syncFullscreenUI(isFs)

      if (!isFs && this._savedStyles) {
        Object.assign(el.style, this._savedStyles)
        this._savedStyles = null
      }

      // Restore transition
      el.offsetHeight // eslint-disable-line no-unused-expressions
      el.style.transition = ''

      requestAnimationFrame(() => this.listController?.scrollToBottom())
    }
  }

  _syncFullscreenUI(entering) {
    if (this.hasFullscreenIconTarget) {
      this.fullscreenIconTarget.style.display = entering ? 'none' : ''
    }
    if (this.hasExitFullscreenIconTarget) {
      this.exitFullscreenIconTarget.style.display = entering ? '' : 'none'
    }
    if (this.hasLeftHandleTarget) {
      this.leftHandleTarget.style.display = entering ? 'none' : ''
    }
    if (this.hasRightHandleTarget) {
      this.rightHandleTarget.style.display = entering ? 'none' : ''
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
  }

  openFromUrl() {
    const params = new URLSearchParams(window.location.search)
    const openComments = params.get('open_comments') === 'true'
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
}
