import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['menu', 'button']

  connect() {
    this.handleOutsideClick = this.handleOutsideClick.bind(this)
  }

  disconnect() {
    this.removeOutsideClickListener()
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
    const menu = this.menuTarget
    menu.style.display = 'block'
    menu.style.transform = ''

    this.buttonTarget?.setAttribute('aria-expanded', 'true')

    requestAnimationFrame(() => {
      const rect = menu.getBoundingClientRect()
      let shift = 0
      if (rect.right > window.innerWidth) {
        shift = rect.right - window.innerWidth + 4
        menu.style.transform = `translateX(-${shift}px)`
      } else if (rect.left < 0) {
        shift = -rect.left + 4
        menu.style.transform = `translateX(${shift}px)`
      }
    })

    this.addOutsideClickListener()
  }

  hide() {
    this.menuTarget.style.display = 'none'
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
