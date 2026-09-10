export default class PopupFullscreen {
  constructor({
    element,
    isMobile,
    isDocked,
    syncUi,
    syncDockedUi,
    getListController,
    getTopicsController,
    getCurrentButton,
    setCurrentButton,
  }) {
    this.element = element
    this.isMobile = isMobile
    this.isDocked = isDocked
    this.syncUi = syncUi
    this.syncDockedUi = syncDockedUi
    this.getListController = getListController
    this.getTopicsController = getTopicsController
    this.getCurrentButton = getCurrentButton
    this.setCurrentButton = setCurrentButton
    this.savedStyles = null
    this.previousUrl = null
    this.enterCleanupTimer = null
    this.enterCleanupFn = null
    this.exitToRight = false
  }

  get active() {
    return this.element.dataset.fullscreen === 'true'
  }

  toggle() {
    if (this.active) return this.exit()

    this.enter()
  }

  enterImmediate() {
    const el = this.element
    this.savedStyles = this.captureStyles()

    el.style.transition = 'none'
    el.dataset.fullscreen = 'true'
    document.body.classList.add('chat-fullscreen')
    this.syncUi(true)
    this.clearPositionStyles()
    el.offsetHeight // eslint-disable-line no-unused-expressions
    el.style.transition = ''

    requestAnimationFrame(() => this.getListController()?.scrollToBottom())
  }

  enter() {
    const el = this.element
    this.savedStyles = this.captureStyles()
    const rect = el.getBoundingClientRect()

    el.style.transition = 'none'
    el.style.position = 'fixed'
    el.style.top = `${rect.top}px`
    el.style.left = `${rect.left}px`
    el.style.right = 'auto'
    el.style.width = `${rect.width}px`
    el.style.height = `${rect.height}px`
    el.offsetHeight // eslint-disable-line no-unused-expressions

    el.style.transition = ''
    el.dataset.fullscreen = 'true'
    document.body.classList.add('chat-fullscreen')
    this.syncUi(true)

    el.style.top = '0'
    el.style.left = '0'
    el.style.right = '0'
    el.style.bottom = '0'
    el.style.width = '100%'
    el.style.height = '100%'

    const creativeId = el.dataset.creativeId
    if (creativeId) {
      this.previousUrl = window.location.href
      window.history.pushState(
        { fullscreen: true },
        '',
        `/creatives/${creativeId}/comments/fullscreen`,
      )
    }

    this.scheduleEnterCleanup()
    this.scrollToBottom()
  }

  exit() {
    this.cancelEnterCleanup()

    const savedStyles = this.savedStyles
    this.savedStyles = null
    const creativeId = this.element.dataset.creativeId

    if (this.isMobile()) {
      this.exitWithoutAnimation()
      this.pushExitUrl(creativeId)
      this.scrollToBottom()
      return
    }

    if (this.isDocked()) {
      this.exitDocked()
      this.pushExitUrl(creativeId)
      this.scrollToBottom()
      return
    }

    this.exitDesktop(savedStyles, creativeId)
    this.scrollToBottom()
  }

  exitState() {
    if (!this.active) return

    this.cancelEnterCleanup()

    const el = this.element
    el.dataset.fullscreen = 'false'
    document.body.classList.remove('chat-fullscreen')
    this.syncUi(false)
    this.savedStyles = null
    el.style.transition = ''
    this.clearPositionStyles({ includeTransform: true })

    const creativeId = el.dataset.creativeId
    const backUrl = this.previousUrl || (creativeId ? `/creatives/${creativeId}` : null)
    if (backUrl) {
      const url = new URL(backUrl, window.location.origin)
      url.searchParams.delete('open_comments')
      url.searchParams.delete('comment_id')
      const cleanPath = url.pathname.replace(/\/comments\/\d+$/, '')
      url.hash = url.hash.replace(/^#comment_\d+$/, '')
      window.history.replaceState(
        { fullscreen: false },
        '',
        cleanPath + url.search + url.hash,
      )
    }
    this.previousUrl = null
  }

  handlePopState(event) {
    const isFullscreen = event.state?.fullscreen === true
    if (isFullscreen === this.active) return

    const el = this.element
    el.style.transition = 'none'
    this.clearPositionStyles()

    el.dataset.fullscreen = isFullscreen ? 'true' : 'false'
    document.body.classList.toggle('chat-fullscreen', isFullscreen)
    this.syncUi(isFullscreen)
    if (!isFullscreen && this.isDocked()) {
      el.style.display = 'flex'
      this.syncDockedUi()
    }

    if (!isFullscreen && this.savedStyles) {
      Object.assign(el.style, this.savedStyles)
      this.savedStyles = null
    }

    el.offsetHeight // eslint-disable-line no-unused-expressions
    el.style.transition = ''
    this.scrollToBottom()
  }

  captureStyles() {
    const { style } = this.element
    return {
      top: style.top,
      right: style.right,
      left: style.left,
      width: style.width,
      height: style.height,
    }
  }

  scheduleEnterCleanup() {
    const el = this.element
    this.enterCleanupFn = () => {
      el.removeEventListener('transitionend', this.enterCleanupFn)
      this.enterCleanupTimer = null
      this.enterCleanupFn = null
      this.clearPositionStyles()
    }
    el.addEventListener('transitionend', this.enterCleanupFn, { once: true })
    this.enterCleanupTimer = setTimeout(this.enterCleanupFn, 300)
  }

  cancelEnterCleanup() {
    if (this.enterCleanupTimer) {
      clearTimeout(this.enterCleanupTimer)
      this.enterCleanupTimer = null
    }
    if (this.enterCleanupFn) {
      this.element.removeEventListener('transitionend', this.enterCleanupFn)
      this.enterCleanupFn = null
    }
  }

  exitWithoutAnimation() {
    const el = this.element
    el.style.transition = 'none'
    el.dataset.fullscreen = 'false'
    document.body.classList.remove('chat-fullscreen')
    this.syncUi(false)
    this.clearPositionStyles({ includeTransform: true })
    el.offsetHeight // eslint-disable-line no-unused-expressions
    el.style.transition = ''
  }

  exitDocked() {
    const el = this.element
    el.style.transition = 'none'
    el.dataset.fullscreen = 'false'
    document.body.classList.remove('chat-fullscreen')
    this.clearPositionStyles()
    this.savedStyles = null
    this.syncUi(false)
    this.syncDockedUi()
    el.offsetHeight // eslint-disable-line no-unused-expressions
    el.style.transition = ''
  }

  exitDesktop(savedStyles, creativeId) {
    const target = this.desktopExitTarget(savedStyles, creativeId)
    const el = this.element
    const fullscreenRect = el.getBoundingClientRect()

    el.style.transition = 'none'
    el.style.position = 'fixed'
    el.style.top = `${fullscreenRect.top}px`
    el.style.left = `${fullscreenRect.left}px`
    el.style.right = 'auto'
    el.style.bottom = 'auto'
    el.style.width = `${fullscreenRect.width}px`
    el.style.height = `${fullscreenRect.height}px`

    el.dataset.fullscreen = 'false'
    document.body.classList.remove('chat-fullscreen')
    this.syncUi(false)
    el.offsetHeight // eslint-disable-line no-unused-expressions

    el.style.transition = ''
    el.style.top = `${target.animTop}px`
    el.style.left = `${target.animLeft}px`
    el.style.width = `${target.animWidth}px`
    el.style.height = `${target.animHeight}px`

    this.scheduleExitCleanup(target, savedStyles)
    this.pushExitUrl(creativeId)
  }

  desktopExitTarget(savedStyles, creativeId) {
    const targetButton = this.findTargetButton(creativeId)
    let finalTop = ''
    let finalRight = ''
    const finalWidth = savedStyles?.width || ''
    const finalHeight = savedStyles?.height || ''
    let animTop
    let animLeft
    let animWidth
    let animHeight

    if (targetButton) {
      this.setCurrentButton(targetButton)
      const btnRect = targetButton.getBoundingClientRect()
      const gap = 8
      animWidth = parseFloat(finalWidth) || 420
      animHeight = parseFloat(finalHeight) || 640

      let top = btnRect.bottom + 4
      if (top + animHeight > window.innerHeight) {
        top = Math.max(4, window.innerHeight - animHeight - 4)
      }
      finalTop = `${top}px`

      if (window.innerWidth - btnRect.right - gap >= animWidth) {
        this.exitToRight = true
        animLeft = btnRect.right + gap
      } else {
        this.exitToRight = false
        const rightPx = window.innerWidth - btnRect.right + 24
        finalRight = `${rightPx}px`
        animLeft = window.innerWidth - rightPx - animWidth
      }
      animTop = top
    } else if (savedStyles && Object.values(savedStyles).some(value => value)) {
      const right = parseFloat(savedStyles.right) || 32
      animWidth = parseFloat(savedStyles.width) || 420
      animHeight = parseFloat(savedStyles.height) || 640
      animLeft = savedStyles.left
        ? parseFloat(savedStyles.left)
        : window.innerWidth - right - animWidth
      animTop = parseFloat(savedStyles.top) || 100
      finalTop = savedStyles.top || ''
      finalRight = savedStyles.right || ''
    } else {
      animWidth = 420
      animHeight = 640
      animLeft = window.innerWidth - 32 - animWidth
      animTop = 100
    }

    return {
      targetButton,
      finalTop,
      finalRight,
      finalWidth,
      finalHeight,
      animTop,
      animLeft,
      animWidth,
      animHeight,
    }
  }

  findTargetButton(creativeId) {
    let targetButton = this.getCurrentButton()
    if (!targetButton && creativeId) {
      const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
      targetButton = row?.querySelector('.comments-btn')
    }
    const row = targetButton?.closest('creative-tree-row')
    row?.scrollIntoView({ behavior: 'instant', block: 'center' })
    return targetButton
  }

  scheduleExitCleanup(target, savedStyles) {
    const el = this.element
    let cleanupTimer = null
    let cleanedUp = false
    const cleanup = () => {
      if (cleanedUp) return
      cleanedUp = true
      if (cleanupTimer !== null) {
        clearTimeout(cleanupTimer)
        cleanupTimer = null
      }
      el.removeEventListener('transitionend', cleanup)
      el.style.transition = 'none'
      el.style.position = ''
      el.style.bottom = ''

      if (target.targetButton) {
        this.restoreTargetButtonStyles(target)
      } else if (savedStyles) {
        this.clearPositionStyles()
        Object.assign(el.style, savedStyles)
      } else {
        this.clearPositionStyles()
      }

      el.offsetHeight // eslint-disable-line no-unused-expressions
      el.style.transition = ''
      this.getTopicsController()?.scrollToActiveTopic()
    }
    el.addEventListener('transitionend', cleanup, { once: true })
    cleanupTimer = setTimeout(cleanup, 300)
  }

  restoreTargetButtonStyles(target) {
    const { style } = this.element
    style.top = target.finalTop
    style.width = target.finalWidth
    style.height = target.finalHeight
    if (this.exitToRight) {
      style.left = `${target.animLeft}px`
      style.right = ''
    } else {
      style.right = target.finalRight
      style.left = ''
    }
  }

  pushExitUrl(creativeId) {
    const backUrl = this.previousUrl || (creativeId ? `/creatives/${creativeId}` : null)
    if (backUrl) {
      const url = new URL(backUrl, window.location.origin)
      url.searchParams.set('open_comments', 'true')
      window.history.pushState(
        { fullscreen: false },
        '',
        url.pathname + url.search,
      )
    }
    this.previousUrl = null
  }

  clearPositionStyles({ includeTransform = false } = {}) {
    const { style } = this.element
    style.position = ''
    style.top = ''
    style.left = ''
    style.right = ''
    style.bottom = ''
    style.width = ''
    style.height = ''
    if (includeTransform) style.transform = ''
  }

  scrollToBottom() {
    requestAnimationFrame(() => this.getListController()?.scrollToBottom())
  }
}
