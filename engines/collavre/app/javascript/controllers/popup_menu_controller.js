import { Controller } from '@hotwired/stimulus'
import { notifyPopupOpen, onOtherPopupOpen } from '../lib/gnb_popup_manager'
import visualViewportRect from '../lib/viewport_region'

// Gap between the button and the menu, and the breathing room kept between the
// menu and the edge of the visible region.
const GAP = 4
const VIEWPORT_PADDING = 4

export default class extends Controller {
  static targets = ['menu', 'button']

  connect() {
    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    this.handleViewportChange = this.handleViewportChange.bind(this)
    this._popupId = 'popup-menu-' + (this.menuTarget.id || this.element.id || this.element.dataset.popupId || Math.random().toString(36).slice(2))
    this._initialAlignRight = this.menuTarget.classList.contains('popup-menu-right')
    this._cleanupPopupListener = onOtherPopupOpen(this._popupId, () => {
      if (this.isOpen()) this.hide()
    })
  }

  disconnect() {
    this.removeOutsideClickListener()
    this.removeViewportListeners()
    if (this._cleanupPopupListener) {
      this._cleanupPopupListener()
      this._cleanupPopupListener = null
    }
  }

  toggle(event) {
    event.stopPropagation()
    if (this.isOpen()) {
      this.hide()
    } else {
      this.show()
    }
  }

  menuClick(event) {
    if (event.target.closest('button, a')) {
      this.hide()
    }
  }

  show() {
    notifyPopupOpen(this._popupId)
    const menu = this.menuTarget

    // Use fixed positioning to avoid creating scrollbars on any parent
    menu.style.position = 'fixed'
    menu.style.left = '0'
    menu.style.right = 'auto'
    menu.style.top = '0'
    menu.style.bottom = 'auto'
    menu.style.transform = ''
    menu.style.maxWidth = `${visualViewportRect().width - VIEWPORT_PADDING * 2}px`
    menu.classList.remove('popup-menu-right')
    // Render invisible while we compute position
    menu.style.visibility = 'hidden'
    menu.style.display = 'block'

    this.buttonTarget?.setAttribute('aria-expanded', 'true')

    requestAnimationFrame(() => {
      this.place()
      menu.style.visibility = ''
    })

    this.addOutsideClickListener()
    this.addViewportListeners()
  }

  // Place the menu against the button, inside the region that is actually on
  // screen. Called again while the menu is open (see handleViewportChange): on
  // mobile the keyboard both shrinks that region and moves the chat sheet the
  // button sits in, so a placement made when the menu opened goes stale.
  place() {
    const menu = this.menuTarget
    const btnRect = this.buttonTarget.getBoundingClientRect()
    const menuRect = menu.getBoundingClientRect()
    const menuW = menuRect.width
    const menuH = menuRect.height
    const region = visualViewportRect()

    // Vertical: prefer below the button, flip above if not enough space
    const spaceBelow = region.bottom - btnRect.bottom - GAP
    const spaceAbove = btnRect.top - GAP - region.top
    let top
    if (menuH <= spaceBelow || spaceBelow >= spaceAbove) {
      top = btnRect.bottom + GAP
    } else {
      top = btnRect.top - GAP - menuH
    }

    // Horizontal: align left edge to button, shift if overflowing
    let left
    if (this._initialAlignRight) {
      // Right-align: menu right edge to button right edge
      left = btnRect.right - menuW
    } else {
      left = btnRect.left
    }

    // Clamp within the visible region
    if (left + menuW > region.right - VIEWPORT_PADDING) {
      left = region.right - VIEWPORT_PADDING - menuW
    }
    if (left < region.left + VIEWPORT_PADDING) {
      left = region.left + VIEWPORT_PADDING
    }
    if (top + menuH > region.bottom - VIEWPORT_PADDING) {
      top = region.bottom - VIEWPORT_PADDING - menuH
    }
    if (top < region.top + VIEWPORT_PADDING) {
      top = region.top + VIEWPORT_PADDING
    }

    menu.style.left = `${left}px`
    menu.style.top = `${top}px`
  }

  // The keyboard opening/closing resizes the visual viewport, and pinch-zoom
  // scrolls it. Both move the button out from under an open menu.
  handleViewportChange() {
    if (!this.isOpen()) return
    this.menuTarget.style.maxWidth = `${visualViewportRect().width - VIEWPORT_PADDING * 2}px`
    this.place()
  }

  addViewportListeners() {
    window.visualViewport?.addEventListener('resize', this.handleViewportChange)
    window.visualViewport?.addEventListener('scroll', this.handleViewportChange)
  }

  removeViewportListeners() {
    window.visualViewport?.removeEventListener('resize', this.handleViewportChange)
    window.visualViewport?.removeEventListener('scroll', this.handleViewportChange)
  }

  hide() {
    const menu = this.menuTarget
    menu.style.display = 'none'
    menu.style.position = ''
    menu.style.visibility = ''
    menu.style.left = ''
    menu.style.right = ''
    menu.style.top = ''
    menu.style.bottom = ''
    menu.style.maxWidth = ''
    menu.style.transform = ''
    if (this._initialAlignRight) {
      menu.classList.add('popup-menu-right')
    } else {
      menu.classList.remove('popup-menu-right')
    }
    this.buttonTarget?.setAttribute('aria-expanded', 'false')
    this.removeOutsideClickListener()
    this.removeViewportListeners()
  }

  handleOutsideClick(event) {
    if (!this.element.contains(event.target)) {
      this.hide()
    }
  }

  addOutsideClickListener() {
    document.addEventListener('click', this.handleOutsideClick)
  }

  removeOutsideClickListener() {
    document.removeEventListener('click', this.handleOutsideClick)
  }

  isOpen() {
    return this.menuTarget.style.display === 'block'
  }
}
