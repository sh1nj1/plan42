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

    // Prevent native long-press behavior (text selection, context menu,
    // native drag preview) from stealing touch events after ~500ms.
    // Scrolling is handled via touchmove: within tolerance we preventDefault,
    // beyond tolerance we cancel the timer and the user can scroll normally
    // on the next touch.
    e.preventDefault()

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

    // During long-press wait: prevent scroll within tolerance so the
    // timer isn't accidentally cancelled by natural finger tremor causing
    // a scroll offset shift.
    if (this._timer) {
      const dx = Math.abs(touch.clientX - this._startX)
      const dy = Math.abs(touch.clientY - this._startY)
      if (dx > this.moveTolerance || dy > this.moveTolerance) {
        // User intentionally scrolling — cancel long-press, let scroll happen
        this._cancelLongPress()
      } else {
        // Within tolerance — prevent scroll to keep the long-press alive
        e.preventDefault()
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
    // Center the proxy on the touch point
    const rect = this._proxy.getBoundingClientRect()
    const hw = (rect.width || 80) / 2
    const hh = (rect.height || 30) / 2
    this._proxy.style.left = `${x - hw}px`
    this._proxy.style.top = `${y - hh}px`
  }

  _updateDropTarget(x, y) {
    // Use bounding-rect hit testing instead of elementFromPoint.
    // elementFromPoint is unreliable on mobile when z-index, overlays,
    // or reflow timing interfere with the result.
    const PAD = 12 // extra padding for finger imprecision
    const targets = document.querySelectorAll(this.dropTargetSelector)
    let found = null

    for (const target of targets) {
      const rect = target.getBoundingClientRect()
      if (x >= rect.left - PAD && x <= rect.right + PAD &&
          y >= rect.top - PAD && y <= rect.bottom + PAD) {
        found = target
        break
      }
    }

    if (found !== this._currentTarget) {
      this._currentTarget?.classList.remove(this.dragOverClass)
      this._currentTarget = found
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
