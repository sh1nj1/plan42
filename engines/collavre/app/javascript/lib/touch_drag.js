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
 *     getDropTargets() {},              // optional live target resolver
 *     hitTest(el, point, previousHit) {}, // null rejects; otherwise domain hit
 *     onTargetChange(el, { hit, clientX, clientY }) {},
 *     preserveNativeGestures: true,     // native taps/scroll until long press
 *     autoScroll: true,                 // opt in to continuous edge scrolling
 *     scrollContainer(point, target) {}, // element or resolver; defaults to container
 *   })
 *
 *   // onDrop also receives { hit, clientX, clientY } as a second argument.
 *   td.refreshDropTargets() // after asynchronous folder expansion
 *   td.destroy()  // cleanup
 */

const DEFAULT_LONG_PRESS_MS = 400
const DEFAULT_MOVE_TOLERANCE = 10

export default class TouchDragHandler {
  constructor(opts) {
    this.container = opts.container
    this.itemSelector = opts.itemSelector       // optional when singleElement is true
    this.singleElement = opts.singleElement ?? false  // treat container itself as the draggable
    this.dropTargetSelector = opts.dropTargetSelector
    this.longPressMs = opts.longPressMs ?? DEFAULT_LONG_PRESS_MS
    this.moveTolerance = opts.moveTolerance ?? DEFAULT_MOVE_TOLERANCE
    this.proxyClass = opts.proxyClass ?? 'touch-drag-proxy'
    this.dragOverClass = opts.dragOverClass ?? 'drag-over'
    this.draggingClass = opts.draggingClass ?? 'touch-dragging'
    this.onDragStart = opts.onDragStart
    this.onDrop = opts.onDrop
    this.onCancel = opts.onCancel
    this.onTap = opts.onTap
    this.preserveNativeGestures = opts.preserveNativeGestures ?? false
    this.canStart = opts.canStart
    this.proxyContent = opts.proxyContent
    this.getDropTargets = opts.getDropTargets ?? (() => document.querySelectorAll(this.dropTargetSelector))
    this.hitTest = opts.hitTest
    this.onTargetChange = opts.onTargetChange
    this.autoScroll = opts.autoScroll ?? false
    this.scrollContainer = opts.scrollContainer ?? this.container
    this.scrollEdge = opts.scrollEdge ?? 40
    this.scrollSpeed = opts.scrollSpeed ?? 12

    // State
    this._timer = null
    this._dragging = false
    this._proxy = null
    this._startX = 0
    this._startY = 0
    this._currentTarget = null
    this._currentHit = null
    this._point = null
    this._frame = null

    // Bind handlers
    this._onTouchStart = this._handleTouchStart.bind(this)
    this._onTouchMove = this._handleTouchMove.bind(this)
    this._onTouchEnd = this._handleTouchEnd.bind(this)
    this._onNativeGesture = this._handleNativeGesture.bind(this)
    for (const type of ['contextmenu', 'selectstart', 'dragstart']) {
      document.addEventListener(type, this._onNativeGesture, { capture: true })
    }

    this.container.addEventListener('touchstart', this._onTouchStart, { passive: false })
    this.container.addEventListener('touchmove', this._onTouchMove, { passive: false })
    this.container.addEventListener('touchend', this._onTouchEnd, { passive: false })
    this.container.addEventListener('touchcancel', this._onTouchEnd, { passive: false })
  }

  cancel() {
    if (this._dragging) this.onCancel?.()
    this._endDrag()
  }

  destroy() {
    this._cancelLongPress()
    this._endDrag()
    this.container.removeEventListener('touchstart', this._onTouchStart)
    this.container.removeEventListener('touchmove', this._onTouchMove)
    this.container.removeEventListener('touchend', this._onTouchEnd)
    this.container.removeEventListener('touchcancel', this._onTouchEnd)
    for (const type of ['contextmenu', 'selectstart', 'dragstart']) {
      document.removeEventListener(type, this._onNativeGesture, { capture: true })
    }
  }

  // ── Private ───────────────────────────────────────────────

  _handleTouchStart(e) {
    if (e.touches?.length > 1) { this.cancel(); return }
    if (this._dragging) return

    const touch = e.touches?.[0]
    if (!touch) return
    if (this.canStart && !this.canStart(touch, e)) return

    if (this.singleElement) {
      // In single-element mode, the container itself is the draggable
    } else {
      // Must start on a selected item
      const item = touch.target.closest?.(this.itemSelector)
      if (!item) return

      // Ignore if started on interactive elements
      if (touch.target.closest('input, button, a, textarea, .comment-select')) return
    }

    this._startX = touch.clientX
    this._startY = touch.clientY

    // Legacy avatar-only consumers replay taps themselves. Delegated tree
    // sources retain native taps and scrolling until the long press commits.
    if (!this.preserveNativeGestures) e.preventDefault()

    this._cancelLongPress()
    this._timer = setTimeout(() => {
      this._startDrag(touch)
    }, this.longPressMs)
  }

  _handleTouchMove(e) {
    const touch = e.touches?.[0]
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
      } else if (!this.preserveNativeGestures) {
        // Legacy consumers opt into suppressing native gestures while waiting.
        e.preventDefault()
      }
    }
  }

  _handleTouchEnd(e) {
    if (this._timer) {
      this._cancelLongPress()
      if (e.type !== 'touchcancel' && !this.preserveNativeGestures) this.onTap?.(e)
      return
    }

    if (!this._dragging) return

    e.preventDefault()

    try {
      if (e.type !== 'touchcancel') {
        const touch = e.changedTouches?.[0]
        if (touch) this._moveDrag(touch)
        else this.refreshDropTargets()
      }
      if (e.type !== 'touchcancel' && this._currentTarget) {
        this.onDrop?.(this._currentTarget, { ...this._point, hit: this._currentHit })
      } else {
        this.onCancel?.()
      }
    } finally {
      this._endDrag()
    }
  }

  _handleNativeGesture(e) {
    if (!this._dragging && !this._timer) return
    // The bridge dispatches an untrusted dragstart to serialize the gesture.
    // A browser drag would serialize it again and can cancel the touch stream.
    if (e.type === 'dragstart' && !e.isTrusted) return
    e.preventDefault()
    if (e.type === 'dragstart') e.stopImmediatePropagation()
  }

  _startDrag(touch) {
    this._timer = null

    // Collect matched items (or the container itself in single-element mode)
    const items = this.singleElement
      ? [this.container]
      : this.container.querySelectorAll(this.itemSelector)
    if (!items || items.length === 0) return

    // Let caller cancel
    if (this.onDragStart && this.onDragStart(items, touch) === false) return

    this._dragging = true

    // Vibrate for haptic feedback (if supported)
    if (navigator.vibrate) navigator.vibrate(30)

    // Add class to container
    this.container.classList.add(this.draggingClass)

    // Create floating proxy
    this._proxy = document.createElement('div')
    this._proxy.className = this.proxyClass
    this._proxy.style.pointerEvents = 'none'
    this._proxy.style.position = 'fixed'
    this._proxy.style.zIndex = '10000'
    this._proxy.setAttribute('aria-hidden', 'true')
    const content = this.proxyContent?.(items) ?? `${items.length}`
    if (content instanceof Node) this._proxy.appendChild(content)
    else this._proxy.innerHTML = content
    document.body.appendChild(this._proxy)
    this._moveDrag(touch)
    if (this.autoScroll) this._scheduleScroll()
  }

  _moveDrag(touch) {
    this._point = { clientX: touch.clientX, clientY: touch.clientY }
    this._moveProxy(touch.clientX, touch.clientY)
    this._updateDropTarget(touch.clientX, touch.clientY)
  }

  _moveProxy(x, y) {
    if (!this._proxy) return
    // Cache proxy dimensions on first call (size doesn't change during drag)
    if (this._proxyHW === undefined) {
      const rect = this._proxy.getBoundingClientRect()
      this._proxyHW = (rect.width || 80) / 2
      this._proxyHH = (rect.height || 30) / 2
    }
    this._proxy.style.left = `${x - this._proxyHW}px`
    this._proxy.style.top = `${y - this._proxyHH}px`
  }

  _updateDropTarget(x, y) {
    // Use bounding-rect hit testing instead of elementFromPoint.
    // elementFromPoint is unreliable on mobile when z-index, overlays,
    // or reflow timing interfere with the result.
    const PAD = 12 // extra padding for finger imprecision
    // Resolve each time: expanding folders can add or remove targets mid-drag.
    const targets = this.getDropTargets()
    let found = null
    let hit = null

    for (const target of targets) {
      const rect = target.getBoundingClientRect()
      if (!target.isConnected || rect.width <= 0 || rect.height <= 0) continue
      if (x >= rect.left - PAD && x <= rect.right + PAD &&
          y >= rect.top - PAD && y <= rect.bottom + PAD) {
        hit = this.hitTest ? this.hitTest(target, { clientX: x, clientY: y },
          target === this._currentTarget ? this._currentHit : null) : 'into'
        if (hit == null || hit === false) continue
        found = target
        break
      }
    }

    if (found !== this._currentTarget || hit !== this._currentHit) {
      this._currentTarget?.classList.remove(this.dragOverClass)
      this._currentTarget = found
      this._currentHit = found ? hit : null
      this._currentTarget?.classList.add(this.dragOverClass)
      this.onTargetChange?.(found, { clientX: x, clientY: y, hit: this._currentHit })
    }
  }

  // Call after asynchronous folder expansion, even if the finger has not moved.
  refreshDropTargets() {
    if (this._dragging && this._point) {
      this._updateDropTarget(this._point.clientX, this._point.clientY)
    }
  }

  _scheduleScroll() {
    this._frame = requestAnimationFrame(() => {
      this._frame = null
      if (!this._dragging) return
      const container = typeof this.scrollContainer === 'function'
        ? this.scrollContainer(this._point, this._currentTarget) : this.scrollContainer
      if (container && this._point) {
        const doc = container.ownerDocument
        const rect = container === doc.scrollingElement
          ? { top: 0, left: 0, right: doc.defaultView.innerWidth, bottom: doc.defaultView.innerHeight }
          : container.getBoundingClientRect()
        const { clientX: x, clientY: y } = this._point
        if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
          const distance = y < rect.top + this.scrollEdge ? y - rect.top - this.scrollEdge
            : y > rect.bottom - this.scrollEdge ? y - rect.bottom + this.scrollEdge : 0
          container.scrollTop += Math.round(distance / this.scrollEdge * this.scrollSpeed)
        }
      }
      this.refreshDropTargets()
      this._scheduleScroll()
    })
  }

  _endDrag() {
    this._dragging = false
    if (this._frame !== null) cancelAnimationFrame(this._frame)
    this._frame = null
    this._cancelLongPress()

    this.container.classList.remove(this.draggingClass)

    if (this._currentTarget) {
      this._currentTarget.classList.remove(this.dragOverClass)
      this._currentTarget = null
      this.onTargetChange?.(null, { ...this._point, hit: null })
    }
    this._currentHit = null
    this._point = null

    if (this._proxy) {
      this._proxy.remove()
      this._proxy = null
      this._proxyHW = undefined
      this._proxyHH = undefined
    }
  }

  _cancelLongPress() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
  }
}
