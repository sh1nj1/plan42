import { getDragKind, readDragData } from './envelope'

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

  const resolveZone = (event, usePreview = false) => {
    const kind = getKind(event.dataTransfer)
    let match = null
    for (const zone of zones) {
      const element = matchingElement(root, event, zone.selector)
      if (!element || !acceptsKind(zone.accepts, kind, event)) continue
      if (!match || match.element.contains(element)) match = { zone, element }
    }
    if (!match) return null

    const { zone, element } = match
    const previousHit = activeDrop?.zone === zone && activeDrop.element === element
      ? activeDrop.hit : null
    const hit = usePreview && previousHit
      ? previousHit : (zone.hitTest ? zone.hitTest({ el: element, event, kind, previousHit }) : true)
    return hit ? { zone, element, hit, kind } : null
  }

  const handleDragStart = (event) => {
    const source = sources.find((candidate) => matchingElement(root, event, candidate.selector))
    if (!source) return

    const element = matchingElement(root, event, source.selector)
    activeSource = { source, element }
    try {
      source.onDragStart({ el: element, event })
    } catch (error) {
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

      const data = readData(event.dataTransfer)
      if (!data || data.kind !== resolved.kind) return

      event.preventDefault()
      Promise.resolve(resolved.zone.onDrop({
        el: resolved.element,
        event,
        hit: resolved.hit,
        ...data,
      })).catch(error => reportError(onError, error))
    } catch (error) {
      reportError(onError, error)
    } finally {
      clearPreview()
      activeDrop = null
    }
  }

  root.addEventListener('dragstart', handleDragStart)
  root.addEventListener('dragend', handleDragEnd)
  root.addEventListener('dragover', handleDragOver)
  root.addEventListener('dragleave', handleDragLeave)
  root.addEventListener('drop', handleDrop)

  return {
    registerDragSource(source) {
      if (!source?.selector || typeof source.onDragStart !== 'function') {
        throw new TypeError('A drag source requires selector and onDragStart')
      }
      sources.push(source)
      return () => {
        const index = sources.indexOf(source)
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
      handleDragEnd({ type: 'destroy' })
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
}
