import TouchDragHandler from '../touch_drag'

// Feed touch input through the same DOM events as native dragging so source
// serialization, target policy, previews and business commands have one owner.
export function createTouchBridge({ root, registry }) {
  const document = root.ownerDocument || root
  const container = root.nodeType === 9 ? document.documentElement : root
  let source = null
  let dataTransfer = null
  let lastTarget = null
  let tapTarget = null

  function dispatch(type, target, point = {}) {
    const event = new Event(type, { bubbles: true, cancelable: true })
    Object.assign(event, { dataTransfer, clientX: point.clientX ?? 0,
      clientY: point.clientY ?? 0, shiftKey: false })
    target.dispatchEvent(event)
    return event
  }

  function finish() {
    if (source) dispatch('dragend', source)
    source = null
    dataTransfer = null
    lastTarget = null
  }

  function targetAtPoint(el, point) {
    const actual = document.elementFromPoint?.(point.clientX, point.clientY)
    return actual ? (el.contains(actual) ? actual : null) : el
  }

  const handler = new TouchDragHandler({
    container,
    singleElement: true,
    canStart(touch) {
      if (!registry.getDragSource(touch.target)) return false
      // Text editing keeps native focus/selection; other accepted sources retain
      // their normal click when the gesture ends before the long press.
      if (touch.target.closest('input, textarea, select, [contenteditable="true"]')) return false
      tapTarget = touch.target
      return true
    },
    onTap() {
      if (tapTarget?.isConnected) tapTarget.click()
      tapTarget = null
    },
    getDropTargets: () => registry.getDropTargets(),
    autoScroll: true,
    scrollContainer(point, target) {
      let el = target || document.elementFromPoint?.(point.clientX, point.clientY)
      while (el) {
        const overflow = document.defaultView.getComputedStyle(el).overflowY
        if (/(auto|scroll)/.test(overflow) && el.scrollHeight > el.clientHeight) return el
        el = el.parentElement
      }
      return document.scrollingElement
    },
    onDragStart(_items, touch) {
      source = registry.getDragSource(touch.target)
      if (!source) return false
      const values = new Map()
      dataTransfer = {
        effectAllowed: 'all', dropEffect: 'none',
        get types() { return [...values.keys()] },
        setData(type, value) { values.set(type, String(value)) },
        getData(type) { return values.get(type) || '' },
        clearData(type) { type ? values.delete(type) : values.clear() },
        setDragImage() {},
      }
      const event = dispatch('dragstart', touch.target, touch)
      if (event.defaultPrevented || !dataTransfer.types.length) {
        finish()
        return false
      }
    },
    hitTest(el, point) {
      const target = targetAtPoint(el, point)
      if (!target) return null
      if (lastTarget && lastTarget !== target) dispatch('dragleave', lastTarget, point)
      lastTarget = target
      return dispatch('dragover', target, point).defaultPrevented ? 'into' : null
    },
    onTargetChange(el, point) {
      if (!el && lastTarget) {
        dispatch('dragleave', lastTarget, point)
        lastTarget = null
      }
    },
    onDrop(el, point) {
      try {
        const target = targetAtPoint(el, point)
        if (target) dispatch('drop', target, point)
      } finally { finish() }
    },
    onCancel: finish,
  })

  return {
    refreshDropTargets: () => handler.refreshDropTargets(),
    destroy() {
      finish()
      handler.destroy()
    },
  }
}
