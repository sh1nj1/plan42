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
    this.handleOnline = this.handleOnline.bind(this)
    this.handleWindowFocus = this.handleWindowFocus.bind(this)
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this)

    document.addEventListener(CREATIVE_CLICK_EVENT, this.handleCreativeClick)
    window.addEventListener('online', this.handleOnline)
    window.addEventListener('focus', this.handleWindowFocus)
    document.addEventListener('visibilitychange', this.handleVisibilityChange)

    this.closeButtonTarget?.addEventListener('click', () => this.close())
    this.leftHandleTarget?.addEventListener('mousedown', (event) => this.startResize(event, 'left'))
    this.rightHandleTarget?.addEventListener('mousedown', (event) => this.startResize(event, 'right'))

    if (this.isMobile()) {
      this.element.addEventListener('touchstart', this.handleTouchStart)
      this.element.addEventListener('touchend', this.handleTouchEnd)
    }

    document.querySelectorAll('form[action="/session"]').forEach((form) => {
      form.addEventListener('submit', () => window.localStorage.removeItem(SIZE_STORAGE_KEY))
    })

    this.openFromUrl()
  }

  disconnect() {
    this.clearPendingOpenFromUrl()
    document.removeEventListener(CREATIVE_CLICK_EVENT, this.handleCreativeClick)
    window.removeEventListener('online', this.handleOnline)
    window.removeEventListener('focus', this.handleWindowFocus)
    document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    window.removeEventListener('mousemove', this.handleResizeMove)
    window.removeEventListener('mouseup', this.handleResizeStop)
    if (this.isMobile()) {
      this.element.removeEventListener('touchstart', this.handleTouchStart)
      this.element.removeEventListener('touchend', this.handleTouchEnd)
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

  open(button, { creativeId, highlightId } = {}) {
    this.currentButton = button
    const resolvedCreativeId = creativeId || button?.dataset.creativeId
    const canComment = button.dataset.canComment === 'true'
    const snippet = button.dataset.creativeSnippet || ''

    this.element.dataset.creativeId = resolvedCreativeId || ''
    this.element.dataset.canComment = canComment ? 'true' : 'false'
    this.titleTarget.textContent = snippet

    this.prepareSize()

    if (this.formController) {
      this.formController.onPopupOpened({ creativeId: resolvedCreativeId, canComment })
    }
    if (this.listController) {
      this.listController.onPopupOpened({ creativeId: resolvedCreativeId, highlightId })
    }
    if (this.presenceController) {
      this.presenceController.onPopupOpened({ creativeId: resolvedCreativeId })
    }
    if (this.mentionMenuController) {
      this.mentionMenuController.onPopupOpened({ creativeId: resolvedCreativeId })
    }

    this.showPopup()
    this.updatePosition()
    document.body.classList.add('no-scroll')
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
    if (this.isMobile()) {
      this.element.style.display = 'flex'
      this.element.classList.add('open')
    } else {
      this.element.style.display = 'flex'
    }
  }

  isMobile() {
    return window.innerWidth <= 600
  }

  updatePosition() {
    if (!this.currentButton || this.isMobile() || this.element.dataset.resized === 'true') return
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

  openFromUrl() {
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

    let creativeId = params.get('id')
    if (!creativeId) {
      const pathCreativeMatch = window.location.pathname.match(/\/creatives\/(\d+)/)
      if (pathCreativeMatch) {
        creativeId = pathCreativeMatch[1]
      }
    }

    if (!commentId || !creativeId) return
    const selector = `[name="show-comments-btn"][data-creative-id="${creativeId}"]`
    const tryOpenWithButton = () => {
      const button = document.querySelector(selector)
      if (!button) return false
      this.clearPendingOpenFromUrl()
      this.open(button, { highlightId: commentId })
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
