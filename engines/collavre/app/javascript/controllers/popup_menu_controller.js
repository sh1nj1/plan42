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

    menu.style.display = 'block'
    menu.style.transform = ''
    menu.style.maxWidth = `calc(100vw - ${viewportPadding * 2}px)`
    if (this._initialAlignRight) {
      menu.classList.add('popup-menu-right')
    } else {
      menu.classList.remove('popup-menu-right')
    }
    menu.style.top = 'calc(100% + 4px)'
    menu.style.bottom = 'auto'

    this.buttonTarget?.setAttribute('aria-expanded', 'true')

    requestAnimationFrame(() => {
      const transforms = []
      let rect = menu.getBoundingClientRect()
      const spaceBelow = window.innerHeight - rect.bottom
      const spaceAbove = rect.top

      if (rect.bottom > window.innerHeight && spaceAbove > spaceBelow) {
        menu.style.top = 'auto'
        menu.style.bottom = 'calc(100% + 4px)'
        rect = menu.getBoundingClientRect()
      }

      if (rect.right > window.innerWidth - viewportPadding) {
        menu.classList.add('popup-menu-right')
        rect = menu.getBoundingClientRect()
      }

      if (rect.left < viewportPadding && menu.classList.contains('popup-menu-right')) {
        menu.classList.remove('popup-menu-right')
        rect = menu.getBoundingClientRect()
      }

      if (rect.right > window.innerWidth - viewportPadding) {
        transforms.push(`translateX(-${rect.right - window.innerWidth + viewportPadding}px)`)
      } else if (rect.left < viewportPadding) {
        transforms.push(`translateX(${viewportPadding - rect.left}px)`)
      }

      if (rect.bottom > window.innerHeight - viewportPadding) {
        transforms.push(`translateY(-${rect.bottom - window.innerHeight + viewportPadding}px)`)
      } else if (rect.top < viewportPadding) {
        transforms.push(`translateY(${viewportPadding - rect.top}px)`)
      }

      menu.style.transform = transforms.join(' ')
    })

    this.addOutsideClickListener()
  }

  hide() {
    const menu = this.menuTarget
    menu.style.display = 'none'
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
