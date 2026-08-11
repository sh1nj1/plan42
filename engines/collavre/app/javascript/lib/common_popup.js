// Gap between the anchor (caret, button) and the popup edge.
const ANCHOR_GAP = 4
// Breathing room kept between the popup and the edge of its region.
const BOUNDS_PADDING = 8
// Floor for the space-derived max-height. Header + search input already eat
// ~90px, so anything under this leaves no list at all; overflowing the region
// slightly beats rendering a sliver.
const MIN_POPUP_HEIGHT = 160

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
    // Pending showAt placement frame, so hide() can cancel it.
    this._openFrame = null

    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    this.handleViewportResize = this.handleViewportResize.bind(this)
  }

  showAt(anchorRect, boundsElement = null) {
    if (!this.element) return

    // When set, the popup is caged inside this element's rect (e.g. the chat
    // box) instead of the viewport — see updatePosition.
    this._boundsElement = boundsElement
    // Kept so reposition() can re-place against the same anchor after the
    // popup's content has changed size.
    this._anchorRect = anchorRect
    this._placedAbove = false

    // Re-opening while already open (e.g. clicking the same typo mark twice):
    // a listener from the previous open is still live, so the opening mousedown
    // would bubble to it and hide() the popup right after we set display:block,
    // leaving it stuck (the rAF below only re-flips visibility, not display).
    // Drop stale listeners first so the opening event can't self-close it.
    document.removeEventListener('mousedown', this.handleOutsideClick)
    document.removeEventListener('touchstart', this.handleOutsideClick)

    this.element.style.display = 'block'
    this.element.style.visibility = 'hidden'

    cancelAnimationFrame(this._openFrame)
    this._openFrame = requestAnimationFrame(() => {
      this._openFrame = null
      // The popup can be gone before this frame runs: hide() on a rapid
      // open/close, or a Turbo navigation that tears the element out of the
      // document without closing the popup. Registering here regardless would
      // leave document/visualViewport holding this popup and its detached
      // element forever, and hide()'s removals already ran against listeners
      // that did not exist yet.
      if (!this.isOpen() || !this.element.isConnected) return

      this.updatePosition(anchorRect)
      this.element.style.visibility = 'visible'
      // Register the outside-click listeners only after the opening event has
      // finished propagating. When a popup is opened from a mousedown handler
      // (e.g. clicking a typo highlight), registering synchronously here would
      // let that same mousedown keep bubbling to document, hit handleOutsideClick
      // (target is outside the popup), and immediately hide() it — the popup
      // would open and instantly vanish. Deferring one frame avoids that race.
      if (this.closeOnOutsideClick) {
        document.addEventListener('mousedown', this.handleOutsideClick)
        document.addEventListener('touchstart', this.handleOutsideClick)
      }
      // The on-screen keyboard shrinks the visual viewport without firing a
      // window resize, and it opens *after* showAt (the consumer focuses its
      // input a frame later), so the placement made here is already stale.
      window.visualViewport?.addEventListener('resize', this.handleViewportResize)
    })
  }

  // Re-run placement against the anchor showAt was given. Call this whenever the
  // popup's content changes size: showAt measures one frame after opening, so a
  // popup whose body arrives asynchronously (a fetched tree, search results) was
  // sized while it still read "Loading…" and would otherwise keep the placement
  // that placeholder height implied.
  reposition() {
    if (!this.isOpen()) return
    this.updatePosition(this._anchorRect)
  }

  handleViewportResize() {
    this.reposition()
  }

  // The region the popup must stay inside: an explicit bounds element (the chat
  // box) when caged, otherwise the visual viewport. window.innerHeight is the
  // wrong number on mobile — it still counts the strip the keyboard covers.
  regionRect() {
    const bounds = this._boundsElement?.getBoundingClientRect?.()
    if (bounds) return bounds

    const viewport = window.visualViewport
    const left = viewport?.offsetLeft || 0
    const top = viewport?.offsetTop || 0
    const width = viewport?.width || window.innerWidth
    const height = viewport?.height || window.innerHeight
    return { left, top, right: left + width, bottom: top + height, width, height }
  }

  updatePosition(anchorRect) {
    if (!this.element) return

    const offsetParent = this.element.offsetParent
    const parentRect = offsetParent?.getBoundingClientRect?.() || { left: 0, top: 0 }
    const parentScrollX = offsetParent?.scrollLeft || 0
    const parentScrollY = offsetParent?.scrollTop || 0
    const rect = anchorRect || this.element.getBoundingClientRect()
    const anchorTop = rect?.top || 0
    const anchorBottom = rect?.bottom || 0

    // Measure unconstrained. A max-height left behind by an earlier placement
    // would make offsetHeight report that cap instead of the content height, so
    // every later call would agree the popup "fits" wherever it was first put.
    this.element.style.maxHeight = ''
    const { offsetWidth: width, offsetHeight: height } = this.element

    const region = this.regionRect()
    const spaceBelow = region.bottom - BOUNDS_PADDING - (anchorBottom + ANCHOR_GAP)
    const spaceAbove = (anchorTop - ANCHOR_GAP) - (region.top + BOUNDS_PADDING)

    // Flip above the anchor when the popup genuinely does not fit below it and
    // there is more room up there — a chat composer pinned to the bottom of the
    // screen leaves almost nothing under the caret. Once flipped, stay flipped
    // for the rest of this open: content that shrinks again (collapsing tree
    // nodes) must not make the popup hop back across the anchor.
    const placeAbove = this._placedAbove || (height > spaceBelow && spaceAbove > spaceBelow)
    this._placedAbove = placeAbove

    // Cap to the space actually available so the list scrolls inside the popup
    // instead of running off-screen, both now and if the content grows later.
    const available = Math.max(placeAbove ? spaceAbove : spaceBelow, MIN_POPUP_HEIGHT)
    this.element.style.maxHeight = `${available}px`
    if (this._boundsElement) {
      this.element.style.maxWidth = `${region.width - BOUNDS_PADDING * 2}px`
    }
    const renderedHeight = Math.min(height, available)

    let viewportLeft = rect?.left || 0
    let viewportTop = placeAbove
      ? anchorTop - ANCHOR_GAP - renderedHeight
      : anchorBottom + ANCHOR_GAP

    const minLeft = region.left + BOUNDS_PADDING
    const maxLeft = region.right - width - BOUNDS_PADDING
    const minTop = region.top + BOUNDS_PADDING
    const maxTop = region.bottom - renderedHeight - BOUNDS_PADDING

    viewportLeft = Math.max(minLeft, Math.min(viewportLeft, maxLeft))
    viewportTop = Math.max(minTop, Math.min(viewportTop, maxTop))

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
    // Drop a placement frame that has not run yet, so it cannot re-show and
    // re-register listeners after this close.
    cancelAnimationFrame(this._openFrame)
    this._openFrame = null
    this.element.style.display = 'none'
    this.element.style.visibility = ''
    this.items = []
    this.activeIndex = -1
    this.updateActiveItem()

    document.removeEventListener('mousedown', this.handleOutsideClick)
    document.removeEventListener('touchstart', this.handleOutsideClick)
    window.visualViewport?.removeEventListener('resize', this.handleViewportResize)
    this._anchorRect = null

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
