import TouchDragHandler from '../touch_drag'

// Feed touch input through the same DOM events as native dragging so source
// serialization, target policy, previews and business commands have one owner.
function attachTouchBridge({ root, registry }) {
  const document = root.ownerDocument || root
  const container = document.documentElement
  let source = null
  let dataTransfer = null
  let lastTarget = null
  let dragImage = null

  function dispatch(type, target, point = {}) {
    const event = new Event(type, { bubbles: true, cancelable: true })
    Object.assign(event, { dataTransfer, clientX: point.clientX ?? 0,
      clientY: point.clientY ?? 0, shiftKey: false })
    target.dispatchEvent(event)
    return event
  }

  function finish() {
    const endingSource = source
    source = null
    if (lastTarget) dispatch('dragleave', lastTarget)
    if (endingSource) dispatch('dragend', endingSource)
    dataTransfer = null
    lastTarget = null
    dragImage = null
  }

  function targetAtPoint(el, point) {
    if (!document.elementFromPoint) return el
    const actual = document.elementFromPoint(point.clientX, point.clientY)
    return actual && el.contains(actual) ? actual : null
  }

  const handler = new TouchDragHandler({
    container,
    singleElement: true,
    preserveNativeGestures: true,
    canStart(touch) {
      if (!registry.getDragSource(touch.target)) return false
      // Editing keeps native focus and selection. Other sources retain native
      // taps and swipes until the long press commits; no synthetic click replay.
      if (touch.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')) return false
      return true
    },
    getDropTargets: () => registry.getDropTargets(),
    proxyContent: () => dragImage,
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
        setDragImage(image) {
          // Reuse the shared bundle artwork without mounting a cloned source
          // component (which could register controllers and duplicate IDs).
          if (!image?.classList.contains('drag-bundle-image')) return
          dragImage = image.cloneNode(true)
          Object.assign(dragImage.style, { position: 'relative', top: '0', left: '0', height: '42px' })
        },
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
    cancel() {
      finish()
      handler.cancel()
    },
    refreshDropTargets: () => handler.refreshDropTargets(),
    destroy() {
      finish()
      handler.destroy()
    },
  }
}

// Controllers can register overlapping roots. One gesture must serialize and
// finish only once, including when it crosses into another controller's pane.
const bridges = new WeakMap()

export function createTouchBridge({ root, registry }) {
  const document = root.ownerDocument || root
  let shared = bridges.get(document)
  if (!shared) {
    const registries = new Set()
    const bridge = attachTouchBridge({ root: document, registry: {
      getDragSource(target) {
        let source = null
        for (const candidate of registries) {
          const match = candidate.getDragSource(target)
          if (match && (!source || source.contains(match))) source = match
        }
        return source
      },
      getDropTargets() {
        return registries.values().next().value?.getDropTargets() || []
      },
    } })
    shared = { registries, bridge }
    bridges.set(document, shared)
  }
  shared.registries.add(registry)
  let destroyed = false
  return {
    refreshDropTargets: () => shared.bridge.refreshDropTargets(),
    cancel: () => shared.bridge.cancel(),
    destroy() {
      if (destroyed) return
      destroyed = true
      shared.bridge.cancel()
      shared.registries.delete(registry)
      if (shared.registries.size === 0) {
        shared.bridge.destroy()
        bridges.delete(document)
      }
    },
  }
}
