/**
 * Touch-based drag-and-drop for mobile devices.
 *
 * Usage:
 *   const td = new TouchDragHandler({
 *     container: listElement,           // scroll container that holds draggable items
 *     itemSelector: '.comment-item.selected-for-move',
 *     dropTargetSelector: '.topic-drop-target, .topic-creation-container',
 *     longPressMs: 400,
 *     moveTolerance: 10,                // px before long-press is cancelled
 *     proxyClass: 'touch-drag-proxy',
 *     dragOverClass: 'drag-over',
 *     draggingClass: 'touch-dragging',
 *     onDragStart(items) {},            // return false to cancel
 *     onDrop(targetEl) {},              // called when dropped on a valid target
 *     onCancel() {},
 *     proxyContent(items) { return '...' }  // HTML for the drag proxy badge
 *   })
 *
 *   td.destroy()  // cleanup
 */

const DEFAULT_LONG_PRESS_MS = 400
const DEFAULT_MOVE_TOLERANCE = 10

export default class TouchDragHandler {
  constructor(opts) {
    this.container = opts.container
    this.itemSelector = opts.itemSelector
    this.dropTargetSelector = opts.dropTargetSelector
    this.longPressMs = opts.longPressMs ?? DEFAULT_LONG_PRESS_MS
    this.moveTolerance = opts.moveTolerance ?? DEFAULT_MOVE_TOLERANCE
    this.proxyClass = opts.proxyClass ?? 'touch-drag-proxy'
    this.dragOverClass = opts.dragOverClass ?? 'drag-over'
    this.draggingClass = opts.draggingClass ?? 'touch-dragging'
    this.onDragStart = opts.onDragStart
    this.onDrop = opts.onDrop
    this.onCancel = opts.onCancel
    this.proxyContent = opts.proxyContent

    // State
    this._timer = null
    this._dragging = false
    this._proxy = null
    this._startX = 0
    this._startY = 0
    this._currentTarget = null

    // Bind handlers
    this._onTouchStart = this._handleTouchStart.bind(this)
    this._onTouchMove = this._handleTouchMove.bind(this)
    this._onTouchEnd = this._handleTouchEnd.bind(this)
    this._onContextMenu = this._handleContextMenu.bind(this)

    this.container.addEventListener('touchstart', this._onTouchStart, { passive: false })
    this.container.addEventListener('touchmove', this._onTouchMove, { passive: false })
    this.container.addEventListener('touchend', this._onTouchEnd, { passive: false })
    this.container.addEventListener('touchcancel', this._onTouchEnd, { passive: false })
  }

  destroy() {
    this._cancelLongPress()
    this._endDrag()
    this.container.removeEventListener('touchstart', this._onTouchStart)
    this.container.removeEventListener('touchmove', this._onTouchMove)
    this.container.removeEventListener('touchend', this._onTouchEnd)
    this.container.removeEventListener('touchcancel', this._onTouchEnd)
  }

  // ── Private ───────────────────────────────────────────────

  _handleTouchStart(e) {
    if (this._dragging) return

    const touch = e.touches[0]
    if (!touch) return

    // Must start on a selected item
    const item = touch.target.closest?.(this.itemSelector)
    if (!item) return

    // Ignore if started on interactive elements
    if (touch.target.closest('input, button, a, textarea, .comment-select')) return

    this._startX = touch.clientX
    this._startY = touch.clientY
    this._startItem = item

    this._cancelLongPress()
    this._timer = setTimeout(() => {
      this._startDrag(touch)
    }, this.longPressMs)
  }

  _handleTouchMove(e) {
    const touch = e.touches[0]
    if (!touch) return

    if (this._dragging) {
      e.preventDefault()
      this._moveDrag(touch)
      return
    }

    // If not dragging yet, check if we moved too far (cancel long-press)
    if (this._timer) {
      const dx = Math.abs(touch.clientX - this._startX)
      const dy = Math.abs(touch.clientY - this._startY)
      if (dx > this.moveTolerance || dy > this.moveTolerance) {
        this._cancelLongPress()
      }
    }
  }

  _handleTouchEnd(e) {
    if (this._timer) {
      this._cancelLongPress()
      return
    }

    if (!this._dragging) return

    e.preventDefault()

    if (this._currentTarget) {
      this.onDrop?.(this._currentTarget)
    } else {
      this.onCancel?.()
    }

    this._endDrag()
  }

  _handleContextMenu(e) {
    // Suppress native context menu during drag
    if (this._dragging || this._timer) {
      e.preventDefault()
    }
  }

  _startDrag(touch) {
    this._timer = null

    // Collect matched items
    const items = this.container.querySelectorAll(this.itemSelector)
    if (!items || items.length === 0) return

    // Let caller cancel
    if (this.onDragStart && this.onDragStart(items) === false) return

    this._dragging = true

    // Suppress context menu while dragging
    document.addEventListener('contextmenu', this._onContextMenu, { capture: true })

    // Vibrate for haptic feedback (if supported)
    if (navigator.vibrate) navigator.vibrate(30)

    // Add class to container
    this.container.classList.add(this.draggingClass)

    // Create floating proxy
    this._proxy = document.createElement('div')
    this._proxy.className = this.proxyClass
    this._proxy.innerHTML = this.proxyContent?.(items) ?? `${items.length}`
    document.body.appendChild(this._proxy)
    this._moveProxy(touch.clientX, touch.clientY)
  }

  _moveDrag(touch) {
    this._moveProxy(touch.clientX, touch.clientY)
    this._updateDropTarget(touch.clientX, touch.clientY)
  }

  _moveProxy(x, y) {
    if (!this._proxy) return
    this._proxy.style.left = `${x + 12}px`
    this._proxy.style.top = `${y - 30}px`
  }

  _updateDropTarget(x, y) {
    // Hide proxy momentarily to hit-test what's underneath
    if (this._proxy) this._proxy.style.pointerEvents = 'none'
    const el = document.elementFromPoint(x, y)
    if (this._proxy) this._proxy.style.pointerEvents = ''

    const target = el?.closest?.(this.dropTargetSelector) ?? null

    if (target !== this._currentTarget) {
      this._currentTarget?.classList.remove(this.dragOverClass)
      this._currentTarget = target
      this._currentTarget?.classList.add(this.dragOverClass)
    }
  }

  _endDrag() {
    this._dragging = false
    this._cancelLongPress()

    document.removeEventListener('contextmenu', this._onContextMenu, { capture: true })

    this.container.classList.remove(this.draggingClass)

    if (this._currentTarget) {
      this._currentTarget.classList.remove(this.dragOverClass)
      this._currentTarget = null
    }

    if (this._proxy) {
      this._proxy.remove()
      this._proxy = null
    }
  }

  _cancelLongPress() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
    this._startItem = null
  }
}
