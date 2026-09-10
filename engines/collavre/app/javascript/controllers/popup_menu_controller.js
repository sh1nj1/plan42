import { Controller } from '@hotwired/stimulus'
import { notifyPopupOpen, onOtherPopupOpen } from '../lib/gnb_popup_manager'
import visualViewportRect from '../lib/viewport_region'

// Gap between the button and the menu, and the breathing room kept between the
// menu and the edge of the visible region.
const GAP = 4
const VIEWPORT_PADDING = 4
// Floor for the space-derived max-height. A menu squeezed under this shows no
// usable row at all; overhanging the anchor slightly beats rendering a sliver.
// The region ceiling still applies on top of it, so the menu never leaves the
// visible strip no matter how little room the button leaves.
const MIN_MENU_HEIGHT = 120

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
    this.constrainWidth()
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

  // Fit the menu to the width that is actually on screen. CSS resolves
  // min-width over max-width, so the cap alone cannot shrink a menu whose
  // stylesheet floor is wider than the strip -- .popup-menu sets 220px and the
  // comment user popup 240px, while a pinch-zoomed visual viewport is nearer
  // 195px. Left as is, the menu keeps its designed width with the right edge
  // parked outside the visible region, and the scroll listener re-pins it there
  // every frame so that edge can never be reached. Clearing the inline minimum
  // first is what lets the stylesheet value be read back, so pinching out
  // restores the designed width instead of leaving the menu stuck narrow.
  constrainWidth() {
    const menu = this.menuTarget
    const available = visualViewportRect().width - VIEWPORT_PADDING * 2
    menu.style.minWidth = ''
    const floor = parseFloat(getComputedStyle(menu).minWidth) || 0
    if (floor > available) menu.style.minWidth = `${available}px`
    menu.style.maxWidth = `${available}px`
  }

  // Place the menu against the button, inside the region that is actually on
  // screen. Called again while the menu is open (see handleViewportChange): on
  // mobile the keyboard both shrinks that region and moves the chat sheet the
  // button sits in, so a placement made when the menu opened goes stale.
  place() {
    const menu = this.menuTarget
    const btnRect = this.buttonTarget.getBoundingClientRect()
    const region = visualViewportRect()

    // Measure unconstrained. A max-height left behind by an earlier placement
    // would make the menu report that cap as its height, so every later call
    // would agree it "fits" wherever it was first put.
    menu.style.maxHeight = ''
    const menuRect = menu.getBoundingClientRect()
    const menuW = menuRect.width
    const menuH = menuRect.height

    const regionTop = region.top + VIEWPORT_PADDING
    const regionBottom = region.bottom - VIEWPORT_PADDING

    // Vertical: prefer below the button, flip above if not enough space
    const spaceBelow = regionBottom - (btnRect.bottom + GAP)
    const spaceAbove = (btnRect.top - GAP) - regionTop
    const placeBelow = menuH <= spaceBelow || spaceBelow >= spaceAbove

    // Cap to the room actually available so a long menu scrolls inside itself
    // rather than running off the bottom of the screen. Clamping the top alone
    // is not enough: a cron popup listing many tasks is taller than the visual
    // viewport once the keyboard is up, and .popup-menu is overflow:hidden, so
    // everything past the fold would simply be unreachable. The region ceiling
    // keeps the menu inside the visible strip even when the button sits outside
    // it, which is what makes the two clamps below sufficient.
    const available = Math.min(
      Math.max(placeBelow ? spaceBelow : spaceAbove, MIN_MENU_HEIGHT),
      regionBottom - regionTop
    )
    menu.style.maxHeight = `${available}px`
    menu.style.overflowY = 'auto'
    const menuHeight = Math.min(menuH, available)

    let top = placeBelow ? btnRect.bottom + GAP : btnRect.top - GAP - menuHeight

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
    if (top + menuHeight > regionBottom) {
      top = regionBottom - menuHeight
    }
    if (top < regionTop) {
      top = regionTop
    }

    menu.style.left = `${left}px`
    menu.style.top = `${top}px`
  }

  // The keyboard opening/closing resizes the visual viewport, and pinch-zoom
  // scrolls it. Both move the button out from under an open menu.
  handleViewportChange() {
    if (!this.isOpen()) return
    this.constrainWidth()
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
    menu.style.minWidth = ''
    menu.style.maxWidth = ''
    menu.style.maxHeight = ''
    menu.style.overflowY = ''
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
