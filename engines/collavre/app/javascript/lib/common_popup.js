export default class CommonPopup {
  constructor(element, { listElement, onSelect, renderItem, onClose, closeOnOutsideClick = true } = {}) {
    this.element = element
    this.listElement = listElement || element?.querySelector('[data-popup-list]') || element?.querySelector('ul')
    this.onSelect = onSelect || (() => { })
    this.renderItem = renderItem || ((item) => item?.label || '')
    this.onClose = onClose
    this.closeOnOutsideClick = closeOnOutsideClick
    this.items = []
    this.activeIndex = -1

    this.handleOutsideClick = this.handleOutsideClick.bind(this)
  }

  showAt(anchorRect) {
    if (!this.element) return

    this.element.style.display = 'block'
    this.element.style.visibility = 'hidden'

    requestAnimationFrame(() => {
      this.updatePosition(anchorRect)
      this.element.style.visibility = 'visible'
    })

    if (this.closeOnOutsideClick) {
      document.addEventListener('mousedown', this.handleOutsideClick)
      document.addEventListener('touchstart', this.handleOutsideClick)
    }
  }

  updatePosition(anchorRect) {
    if (!this.element) return

    const scrollX = window.scrollX || window.pageXOffset || 0
    const scrollY = window.scrollY || window.pageYOffset || 0
    const offsetParent = this.element.offsetParent
    const parentRect = offsetParent?.getBoundingClientRect?.() || { left: 0, top: 0 }
    const parentScrollX = offsetParent?.scrollLeft || 0
    const parentScrollY = offsetParent?.scrollTop || 0
    const boundsPadding = 8
    const rect = anchorRect || this.element.getBoundingClientRect()

    let viewportLeft = (rect?.left || 0)
    let viewportTop = (rect?.bottom || 0) + 4

    const { offsetWidth: width, offsetHeight: height } = this.element
    const maxLeft = window.innerWidth - width - boundsPadding
    const maxTop = window.innerHeight - height - boundsPadding

    viewportLeft = Math.max(boundsPadding, Math.min(viewportLeft, maxLeft))
    viewportTop = Math.max(boundsPadding, Math.min(viewportTop, maxTop))

    const left = viewportLeft - parentRect.left + parentScrollX
    const top = viewportTop - parentRect.top + parentScrollY

    this.element.style.left = `${left}px`
    this.element.style.top = `${top}px`
  }

  setItems(items = []) {
    this.items = items
    if (!this.listElement) return

    this.listElement.innerHTML = ''
    items.forEach((item, index) => {
      const li = document.createElement('li')
      li.className = 'common-popup-item'
      li.dataset.index = String(index)
      li.innerHTML = this.renderItem(item, index)
      li.addEventListener('mouseenter', () => this.setActiveIndex(index))
      li.addEventListener('mousedown', (event) => event.preventDefault())
      li.addEventListener('click', () => this.handleItemSelect(index))

      // Handle touch events for mobile stability (prevent keyboard dismissal/double-tap issues)
      let touchStartY = null
      li.addEventListener('touchstart', (e) => {
        touchStartY = e.touches[0].clientY
      }, { passive: false })

      li.addEventListener('touchend', (e) => {
        if (touchStartY === null) return
        const diffY = Math.abs(e.changedTouches[0].clientY - touchStartY)
        if (diffY < 10) { // Threshold for tap vs scroll
          e.preventDefault()
          this.handleItemSelect(index)
        }
        touchStartY = null
      })

      this.listElement.appendChild(li)
    })

    this.activeIndex = items.length > 0 ? 0 : -1
    this.updateActiveItem()
  }

  handleItemSelect(index) {
    if (index < 0 || index >= this.items.length) return
    this.activeIndex = index
    this.updateActiveItem()
    const item = this.items[index]
    if (item) {
      this.onSelect(item)
    }
  }

  setActiveIndex(index) {
    if (this.items.length === 0) {
      this.activeIndex = -1
      this.updateActiveItem()
      return
    }

    if (index < 0) {
      this.activeIndex = this.items.length - 1
    } else {
      this.activeIndex = index % this.items.length
    }
    this.updateActiveItem()
  }

  updateActiveItem() {
    if (!this.listElement) return
    const items = Array.from(this.listElement.children)
    items.forEach((item, index) => {
      item.classList.toggle('active', index === this.activeIndex)
    })

    const activeItem = items[this.activeIndex]
    if (activeItem && activeItem.scrollIntoView) {
      activeItem.scrollIntoView({ block: 'nearest' })
    }
  }

  handleKey(event) {
    if (!this.isOpen() || this.items.length === 0) return false

    const key = event.key
    const isCtrl = event.ctrlKey || event.metaKey
    const lowered = key?.toLowerCase?.() || key

    if (key === 'Tab' || key === 'Enter') {
      event.preventDefault()
      this.handleItemSelect(this.activeIndex)
      return true
    }

    if (key === 'ArrowDown' || (isCtrl && lowered === 'n')) {
      event.preventDefault()
      this.setActiveIndex(this.activeIndex + 1)
      return true
    }

    if (key === 'ArrowUp' || (isCtrl && lowered === 'p')) {
      event.preventDefault()
      this.setActiveIndex(this.activeIndex - 1)
      return true
    }

    if (key === 'Escape') {
      this.hide('escape')
      return true
    }

    return false
  }

  hide(reason = 'manual') {
    if (!this.element || !this.isOpen()) return
    this.element.style.display = 'none'
    this.element.style.visibility = ''
    this.items = []
    this.activeIndex = -1
    this.updateActiveItem()

    document.removeEventListener('mousedown', this.handleOutsideClick)
    document.removeEventListener('touchstart', this.handleOutsideClick)

    if (typeof this.onClose === 'function') {
      this.onClose(reason)
    }
  }

  handleOutsideClick(event) {
    if (!this.element) return
    if (!this.element.contains(event.target)) {
      this.hide('outside')
    }
  }

  isOpen() {
    return this.element && this.element.style.display === 'block'
  }
}
