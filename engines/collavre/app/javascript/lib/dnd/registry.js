import { getDragKind, readDragData } from './envelope'
import { createTouchBridge } from './touch_bridge'

const liveRegistries = new Set()

function matchingElement(root, event, selector) {
  const element = event.target?.closest?.(selector)
  if (!element) return null
  return root === document || root === element || root.contains(element) ? element : null
}

function acceptsKind(accepts, kind, event) {
  if (!kind) return false
  if (typeof accepts === 'function') return accepts(kind, event)
  if (Array.isArray(accepts)) return accepts.includes(kind)
  return accepts === kind
}

function reportError(onError, error) {
  try {
    onError(error)
  } catch (reportingError) {
    console.error(reportingError)
  }
}

function previewKey(zone, element, hit) {
  return { zone, element, hit: JSON.stringify(hit) }
}

function samePreview(left, right) {
  return left?.zone === right?.zone && left?.element === right?.element && left?.hit === right?.hit
}

export function createDragDropRegistry({
  root = document,
  touch = true,
  getKind = getDragKind,
  readData = readDragData,
  onError = (error) => console.error(error),
} = {}) {
  if (!root?.addEventListener) throw new TypeError('A drag and drop registry requires an event root')
  if (typeof getKind !== 'function') throw new TypeError('A drag and drop registry requires getKind')
  if (typeof readData !== 'function') throw new TypeError('A drag and drop registry requires readData')

  const sources = []
  const zones = []
  let activeSource = null
  let activeDrop = null
  let activePreview = null
  let previewCleanup = null

  const clearPreview = () => {
    try {
      previewCleanup?.()
    } catch (error) {
      reportError(onError, error)
    }
    previewCleanup = null
    activePreview = null
  }

  const localData = (transfer) => {
    // Never substitute memory for a rejected or cross-window transfer payload.
    if (Array.from(transfer?.types || []).length) return null
    for (const candidate of liveRegistries) {
      const data = candidate.gestureData(root.ownerDocument || root)
      if (data) return data
    }
    return null
  }

  const matchZone = (event) => {
    const kind = getKind(event.dataTransfer) || localData(event.dataTransfer)?.kind
    let match = null
    for (const zone of zones) {
      const element = matchingElement(root, event, zone.selector)
      if (!element || !acceptsKind(zone.accepts, kind, event)) continue
      if (!match || match.element.contains(element)) match = { zone, element }
    }
    return match ? { ...match, kind } : null
  }

  const resolveZone = (event, usePreview = false) => {
    let owner = null
    for (const candidate of liveRegistries) {
      const match = candidate.matchDrop(event)
      if (match && (!owner || (owner.match.element !== match.element && owner.match.element.contains(match.element)))) {
        owner = { registry: candidate, match }
      }
    }
    if (owner?.registry !== registry) return null
    const { zone, element, kind } = owner.match
    const previousHit = activeDrop?.zone === zone && activeDrop.element === element
      ? activeDrop.hit : null
    const hit = usePreview && previousHit
      ? previousHit : (zone.hitTest ? zone.hitTest({ el: element, event, kind, previousHit }) : true)
    return hit ? { zone, element, hit, kind } : null
  }

  const handleDragStart = (event) => {
    let owner = null
    for (const candidate of liveRegistries) {
      const element = candidate.getDragSource(event.target)
      if (element && (!owner || (owner.element !== element && owner.element.contains(element)))) {
        owner = { registry: candidate, element }
      }
    }
    if (owner?.registry !== registry) return
    const source = sources.find((candidate) => matchingElement(root, event, candidate.selector))
    const element = matchingElement(root, event, source.selector)
    for (const candidate of liveRegistries) candidate.finishDrag(event)
    activeSource = { source, element, data: null }
    try {
      if (source.onDragStart({ el: element, event,
        setLocalData: data => { activeSource.data = data },
      }) === false) {
        event.preventDefault()
        handleDragEnd(event)
      }
      event.stopPropagation()
    } catch (error) {
      event.preventDefault()
      activeSource = null
      reportError(onError, error)
    }
  }

  const handleDragEnd = (event) => {
    clearPreview()
    activeDrop = null
    if (!activeSource) return

    const { source, element } = activeSource
    activeSource = null
    try {
      source.onDragEnd?.({ el: element, event })
    } catch (error) {
      reportError(onError, error)
    }
  }

  const handleDragOver = (event) => {
    let resolved
    try {
      resolved = resolveZone(event)
    } catch (error) {
      clearPreview()
      activeDrop = null
      reportError(onError, error)
      return
    }

    if (!resolved) {
      clearPreview()
      activeDrop = null
      return
    }

    event.preventDefault()
    event.stopPropagation()
    const { zone, element, hit, kind } = resolved
    event.dataTransfer.dropEffect = typeof zone.dropEffect === 'function'
      ? zone.dropEffect({ el: element, event, hit, kind })
      : (zone.dropEffect || 'move')
    activeDrop = resolved

    const nextPreview = previewKey(zone, element, hit)
    if (samePreview(activePreview, nextPreview)) return
    clearPreview()
    activePreview = nextPreview
    try {
      previewCleanup = zone.preview?.({ el: element, event, hit, kind }) || null
    } catch (error) {
      reportError(onError, error)
    }
  }

  const handleDragLeave = (event) => {
    if (!activeDrop?.element) return
    if (event.relatedTarget && activeDrop.element.contains(event.relatedTarget)) return
    clearPreview()
    activeDrop = null
  }

  const handleDrop = (event) => {
    let resolved
    try {
      resolved = resolveZone(event, true)
      if (!resolved) return

      const data = readData(event.dataTransfer) || localData(event.dataTransfer)
      if (!data || data.kind !== resolved.kind) return

      event.preventDefault()
      event.stopPropagation()
      Promise.resolve(resolved.zone.onDrop({
        el: resolved.element,
        event,
        hit: resolved.hit,
        ...data,
      })).catch(error => reportError(onError, error))
    } catch (error) {
      reportError(onError, error)
    } finally {
      if (resolved) {
        for (const candidate of liveRegistries) candidate.finishDrag(event)
      } else {
        clearPreview()
        activeDrop = null
      }
    }
  }

  const ownerDocument = root.ownerDocument || root
  const handleKeyDown = (event) => {
    if (event.key !== 'Escape') return
    bridge?.cancel()
    handleDragEnd(event)
  }
  ownerDocument.addEventListener('keydown', handleKeyDown)
  if (root !== ownerDocument) ownerDocument.addEventListener('dragend', handleDragEnd)
  root.addEventListener('dragstart', handleDragStart)
  root.addEventListener('dragend', handleDragEnd)
  root.addEventListener('dragover', handleDragOver)
  root.addEventListener('dragleave', handleDragLeave)
  root.addEventListener('drop', handleDrop)

  const registry = {
    finishDrag: handleDragEnd,
    gestureData(document) {
      return document === ownerDocument ? activeSource?.data : null
    },
    matchDrop: matchZone,
    getDragSource(target) {
      for (const source of sources) {
        const element = matchingElement(root, { target }, source.selector)
        if (element) return element
      }
      return null
    },

    localDropTargets() {
      const selector = zones.map(zone => zone.selector).join(',')
      return selector ? [...(root.matches?.(selector) ? [root] : []), ...root.querySelectorAll(selector)] : []
    },

    getDropTargets() {
      const targets = new Set()
      for (const candidate of liveRegistries) {
        for (const target of candidate.localDropTargets()) {
          if (target.ownerDocument === (root.ownerDocument || root)) targets.add(target)
        }
      }
      // Edge scrolling resolves targets every animation frame, so measure each
      // ancestor chain once instead of on every comparison.
      const depth = element => {
        let count = 0
        for (let parent = element.parentElement; parent; parent = parent.parentElement) count += 1
        return count
      }
      return [...targets]
        .map(element => ({ element, depth: depth(element) }))
        .sort((left, right) => right.depth - left.depth)
        .map(({ element }) => element)
    },

    registerDragSource(source) {
      if (!source?.selector || typeof source.onDragStart !== 'function') {
        throw new TypeError('A drag source requires selector and onDragStart')
      }
      sources.push(source)
      return () => {
        const index = sources.indexOf(source)
        if (activeSource?.source === source) handleDragEnd({ type: 'unregister' })
        if (index >= 0) sources.splice(index, 1)
      }
    },

    registerDropZone(zone) {
      if (!zone?.selector || !zone.accepts || typeof zone.onDrop !== 'function') {
        throw new TypeError('A drop zone requires selector, accepts, and onDrop')
      }
      zones.push(zone)
      return () => {
        if (activeDrop?.zone === zone) {
          clearPreview()
          activeDrop = null
        }
        const index = zones.indexOf(zone)
        if (index >= 0) zones.splice(index, 1)
      }
    },

    destroy() {
      bridge?.destroy()
      liveRegistries.delete(registry)
      handleDragEnd({ type: 'destroy' })
      ownerDocument.removeEventListener('keydown', handleKeyDown)
      if (root !== ownerDocument) ownerDocument.removeEventListener('dragend', handleDragEnd)
      root.removeEventListener('dragstart', handleDragStart)
      root.removeEventListener('dragend', handleDragEnd)
      root.removeEventListener('dragover', handleDragOver)
      root.removeEventListener('dragleave', handleDragLeave)
      root.removeEventListener('drop', handleDrop)
      sources.length = 0
      zones.length = 0
      activeSource = null
      activeDrop = null
    },
  }
  liveRegistries.add(registry)
  const bridge = touch ? createTouchBridge({ root, registry }) : null
  return registry
}
