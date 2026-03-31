import { Controller } from '@hotwired/stimulus'
import { notifyPopupOpen, onOtherPopupOpen } from '../lib/gnb_popup_manager'

export default class extends Controller {
  static targets = ['menu', 'button']

  connect() {
    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    this._popupId = 'popup-menu-' + (this.menuTarget.id || this.element.id || this.element.dataset.popupId || Math.random().toString(36).slice(2))
    this._initialAlignRight = this.menuTarget.classList.contains('popup-menu-right')
    this._cleanupPopupListener = onOtherPopupOpen(this._popupId, () => {
      if (this.isOpen()) this.hide()
    })
  }

  disconnect() {
    this.removeOutsideClickListener()
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
    const viewportPadding = 4
    const gap = 4

    // Use fixed positioning to avoid creating scrollbars on any parent
    menu.style.position = 'fixed'
    menu.style.left = '0'
    menu.style.right = 'auto'
    menu.style.top = '0'
    menu.style.bottom = 'auto'
    menu.style.transform = ''
    menu.style.maxWidth = `calc(100vw - ${viewportPadding * 2}px)`
    menu.classList.remove('popup-menu-right')
    // Render invisible while we compute position
    menu.style.visibility = 'hidden'
    menu.style.display = 'block'

    this.buttonTarget?.setAttribute('aria-expanded', 'true')

    requestAnimationFrame(() => {
      const btnRect = this.buttonTarget.getBoundingClientRect()
      const menuRect = menu.getBoundingClientRect()
      const menuW = menuRect.width
      const menuH = menuRect.height
      const vw = window.innerWidth
      const vh = window.innerHeight

      // Vertical: prefer below the button, flip above if not enough space
      const spaceBelow = vh - btnRect.bottom - gap
      const spaceAbove = btnRect.top - gap
      let top
      if (menuH <= spaceBelow || spaceBelow >= spaceAbove) {
        top = btnRect.bottom + gap
      } else {
        top = btnRect.top - gap - menuH
      }

      // Horizontal: align left edge to button, shift if overflowing
      let left
      if (this._initialAlignRight) {
        // Right-align: menu right edge to button right edge
        left = btnRect.right - menuW
      } else {
        left = btnRect.left
      }

      // Clamp within viewport
      if (left + menuW > vw - viewportPadding) {
        left = vw - viewportPadding - menuW
      }
      if (left < viewportPadding) {
        left = viewportPadding
      }
      if (top + menuH > vh - viewportPadding) {
        top = vh - viewportPadding - menuH
      }
      if (top < viewportPadding) {
        top = viewportPadding
      }

      menu.style.left = `${left}px`
      menu.style.top = `${top}px`
      menu.style.visibility = ''
    })

    this.addOutsideClickListener()
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
