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

    const transforms = []
    const viewportPadding = 4

    this.buttonTarget?.setAttribute('aria-expanded', 'true')

    requestAnimationFrame(() => {
      const rect = menu.getBoundingClientRect()
      if (rect.right > window.innerWidth) {
        transforms.push(`translateX(-${rect.right - window.innerWidth + viewportPadding}px)`)
      } else if (rect.left < 0) {
        transforms.push(`translateX(${Math.abs(rect.left) + viewportPadding}px)`)
      }

      if (rect.bottom > window.innerHeight) {
        transforms.push(`translateY(-${rect.bottom - window.innerHeight + viewportPadding}px)`)
      } else if (rect.top < 0) {
        transforms.push(`translateY(${Math.abs(rect.top) + viewportPadding}px)`)
      }

      menu.style.transform = transforms.join(' ')
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
