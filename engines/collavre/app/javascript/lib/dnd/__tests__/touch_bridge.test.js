/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { createDragDropRegistry } from '../registry'
import { createTouchBridge } from '../touch_bridge'

let registry, bridge, source, zone, drops, previews
function touch(type, y = 50, target = source) {
  const event = new TouchEvent(type, { bubbles: true, cancelable: true })
  Object.defineProperty(event, 'touches', { value: type === 'touchend' || type === 'touchcancel' ? []
    : [{ clientX: 50, clientY: y, target }] })
  target.dispatchEvent(event)
  return event
}
function makeZone() {
  const el = document.createElement('div')
  el.className = 'zone'
  el.getBoundingClientRect = () => ({ top: 0, left: 0, right: 100, bottom: 100, width: 100, height: 100 })
  document.body.appendChild(el)
  return el
}
beforeEach(() => {
  jest.useFakeTimers()
  source = document.createElement('div')
  source.className = 'source'
  document.body.appendChild(source)
  zone = makeZone()
  drops = jest.fn()
  previews = jest.fn(() => jest.fn())
  registry = createDragDropRegistry({ root: document, touch: false, getKind: dt => dt.types.includes('test') ? 'creative' : null,
    readData: dt => JSON.parse(dt.getData('test')) })
  registry.registerDragSource({ selector: '.source', onDragStart: ({ event }) => {
    event.dataTransfer.setData('test', JSON.stringify({ kind: 'creative', ids: ['1'] }))
  } })
  registry.registerDropZone({ selector: '.zone', accepts: ['creative'],
    hitTest: ({ event }) => event.clientY < 30 ? 'up' : event.clientY > 70 ? 'down' : 'child',
    preview: previews, onDrop: drops })
  bridge = createTouchBridge({ root: document, registry })
})
afterEach(() => {
  bridge.destroy()
  registry.destroy()
  document.body.innerHTML = ''
  jest.useRealTimers()
  delete document.elementFromPoint
})

test.each([[10, 'up'], [50, 'child'], [90, 'down']])('touch uses shared directional hit at %s', async (y, hit) => {
  touch('touchstart', y)
  jest.advanceTimersByTime(400)
  touch('touchend')
  await Promise.resolve()
  expect(drops).toHaveBeenCalledWith(expect.objectContaining({ kind: 'creative', ids: ['1'], hit, el: zone }))
  expect(previews).toHaveBeenCalledWith(expect.objectContaining({ hit }))
})

test('ordinary touches are untouched and can scroll', () => {
  const event = touch('touchstart', 50, zone)
  expect(event.defaultPrevented).toBe(false)
  jest.advanceTimersByTime(500)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
})

test('expansion replaces targets while the finger is stationary', () => {
  touch('touchstart')
  jest.advanceTimersByTime(400)
  zone.remove()
  const expanded = makeZone()
  bridge.refreshDropTargets()
  touch('touchend')
  expect(drops).toHaveBeenCalledWith(expect.objectContaining({ el: expanded }))
})

test('cancellation and destruction clear preview, proxy and timers without drop', () => {
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchcancel')
  expect(drops).not.toHaveBeenCalled()
  expect(previews.mock.results[0].value).toHaveBeenCalled()
  touch('touchstart')
  jest.advanceTimersByTime(400)
  bridge.destroy()
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
  expect(jest.getTimerCount()).toBe(0)
})

test('a target registered in another controller receives the same drop', () => {
  zone.remove()
  const pane = document.createElement('section')
  document.body.appendChild(pane)
  const external = makeZone()
  external.className = 'external'
  pane.appendChild(external)
  const onDrop = jest.fn()
  const otherRegistry = createDragDropRegistry({ root: pane, touch: false,
    getKind: dt => dt.types.includes('test') ? 'creative' : null,
    readData: dt => JSON.parse(dt.getData('test')) })
  otherRegistry.registerDropZone({ selector: '.external', accepts: ['creative'], onDrop })
  try {
    touch('touchstart')
    jest.advanceTimersByTime(400)
    touch('touchend')
    expect(onDrop).toHaveBeenCalledWith(expect.objectContaining({ ids: ['1'], el: external }))
  } finally {
    otherRegistry.destroy()
  }
})

test('a source rejecting dragstart does not leave a proxy or timer', () => {
  source.className = 'rejected'
  registry.registerDragSource({ selector: '.rejected', onDragStart: ({ event }) => {
    event.preventDefault()
    return false
  } })
  touch('touchstart')
  jest.advanceTimersByTime(400)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
  expect(jest.getTimerCount()).toBe(0)
  expect(drops).not.toHaveBeenCalled()
})

test('edge scrolling resolves the destination pane while the finger stays still', () => {
  const pane = document.createElement('section')
  pane.style.overflowY = 'auto'
  pane.getBoundingClientRect = zone.getBoundingClientRect
  Object.defineProperties(pane, { scrollHeight: { value: 500 }, clientHeight: { value: 100 } })
  document.body.appendChild(pane)
  pane.appendChild(zone)
  touch('touchstart', 95)
  jest.advanceTimersByTime(450)
  expect(pane.scrollTop).toBeGreaterThan(0)
  touch('touchmove', 250)
  jest.advanceTimersByTime(32)
  touch('touchend')
  expect(drops).not.toHaveBeenCalled()
})

test('moving between targets clears the former registry preview', () => {
  touch('touchstart')
  jest.advanceTimersByTime(450)
  const firstCleanup = previews.mock.results[0].value
  zone.remove()
  makeZone()
  touch('touchmove')
  expect(firstCleanup).toHaveBeenCalled()
})

test('native source adapters can replace transfer data and set a drag image', () => {
  source.className = 'replacement'
  registry.registerDragSource({ selector: '.replacement', onDragStart: ({ event }) => {
    const dt = event.dataTransfer
    dt.setData('old', 'discard')
    dt.clearData('old')
    expect(dt.getData('old')).toBe('')
    dt.setData('another', 'discard')
    dt.clearData()
    expect(dt.types).toEqual([])
    dt.setDragImage(source, 0, 0)
    dt.setData('test', JSON.stringify({ kind: 'creative', ids: ['2'] }))
  } })
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchend')
  expect(drops).toHaveBeenCalledWith(expect.objectContaining({ ids: ['2'] }))
})

test('an element-scoped bridge handles dynamically added sources', () => {
  bridge.destroy()
  bridge = createTouchBridge({ root: document.body, registry })
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchend')
  expect(drops).toHaveBeenCalledTimes(1)
})

test('a source removed during long press cannot begin dragging', () => {
  touch('touchstart')
  source.className = ''
  jest.advanceTimersByTime(400)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
})

test('registry acceptance rules also reject touch targets', () => {
  zone.className = 'blocked'
  registry.registerDropZone({ selector: '.blocked', accepts: ['topic'], onDrop: drops })
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchend')
  expect(drops).not.toHaveBeenCalled()
})

test('a quick tap retains the native nested button action without a duplicate click', () => {
  const button = document.createElement('button')
  source.appendChild(button)
  const click = jest.fn()
  button.addEventListener('click', click)
  expect(touch('touchstart', 50, button).defaultPrevented).toBe(false)
  expect(touch('touchend', 50, button).defaultPrevented).toBe(false)
  expect(click).not.toHaveBeenCalled()
  button.dispatchEvent(new MouseEvent('click', { bubbles: true }))
  expect(click).toHaveBeenCalledTimes(1)
  expect(drops).not.toHaveBeenCalled()
})

test('editable controls retain native touch behavior', () => {
  const input = document.createElement('input')
  source.appendChild(input)
  expect(touch('touchstart', 50, input).defaultPrevented).toBe(false)
  expect(jest.getTimerCount()).toBe(0)
})

test('hit tests receive the actual nested pointer target instead of its zone ancestor', () => {
  const form = document.createElement('form')
  zone.appendChild(form)
  document.elementFromPoint = () => form
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchend')
  expect(drops.mock.calls[0][0].event.target).toBe(form)
})

test('an overlay outside the candidate blocks an otherwise matching rectangle', () => {
  document.elementFromPoint = () => source
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchend')
  expect(drops).not.toHaveBeenCalled()
})

test('source adapters can reject long presses on nested action buttons', () => {
  source.className = 'actions'
  const button = document.createElement('button')
  source.appendChild(button)
  registry.registerDragSource({ selector: '.actions', onDragStart: ({ event }) => {
    expect(event.target).toBe(button)
    if (event.target.closest('button')) { event.preventDefault(); return false }
    event.dataTransfer.setData('test', JSON.stringify({ kind: 'creative', ids: ['1'] }))
  } })
  touch('touchstart', 50, button)
  jest.advanceTimersByTime(400)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
  expect(drops).not.toHaveBeenCalled()
})

test('overlapping registry roots share a single touch gesture and cancellation', () => {
  const onEnd = jest.fn()
  registry.registerDragSource({ selector: '.other', onDragStart: jest.fn(), onDragEnd: onEnd })
  const nested = createDragDropRegistry({ root: document.body })
  const starts = jest.fn()
  source.addEventListener('dragstart', starts)
  try {
    touch('touchstart')
    jest.advanceTimersByTime(400)
    expect(starts).toHaveBeenCalledTimes(1)
    expect(document.querySelectorAll('.touch-drag-proxy')).toHaveLength(1)
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(document.querySelector('.touch-drag-proxy')).toBeNull()
    touch('touchend')
    expect(drops).not.toHaveBeenCalled()
  } finally { nested.destroy() }
})

test('a scoped source can drag into another scoped registry and finish after DOM removal', () => {
  bridge.destroy()
  registry.destroy()
  const sourcePane = document.createElement('section')
  document.body.appendChild(sourcePane)
  sourcePane.appendChild(source)
  const targetPane = document.createElement('section')
  document.body.appendChild(targetPane)
  targetPane.appendChild(zone)
  const getKind = dt => dt.types.includes('test') ? 'creative' : null
  const readData = dt => JSON.parse(dt.getData('test'))
  registry = createDragDropRegistry({ root: sourcePane, getKind, readData })
  const ended = jest.fn()
  registry.registerDragSource({ selector: '.source', onDragEnd: ended, onDragStart: ({ event }) => {
    event.dataTransfer.setData('test', JSON.stringify({ kind: 'creative', ids: ['1'] }))
  } })
  const targetRegistry = createDragDropRegistry({ root: targetPane, getKind, readData })
  const onDrop = jest.fn(() => source.remove())
  targetRegistry.registerDropZone({ selector: '.zone', accepts: ['creative'], onDrop })
  try {
    touch('touchstart')
    jest.advanceTimersByTime(400)
    touch('touchend')
    expect(onDrop).toHaveBeenCalledTimes(1)
    expect(ended).toHaveBeenCalledTimes(1)
  } finally { targetRegistry.destroy() }
})

test('a second finger cancels the drag instead of committing a pinch as a move', () => {
  touch('touchstart')
  jest.advanceTimersByTime(400)
  source.dispatchEvent(new TouchEvent('touchstart', {
    bubbles: true, cancelable: true,
    touches: [{ target: source, clientX: 50, clientY: 50 }, { target: source, clientX: 60, clientY: 60 }],
  }))
  touch('touchend')
  expect(drops).not.toHaveBeenCalled()
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
})

test('the final touch coordinate is revalidated when no touchmove was delivered', () => {
  touch('touchstart')
  jest.advanceTimersByTime(400)
  source.dispatchEvent(new TouchEvent('touchend', { bubbles: true, cancelable: true,
    changedTouches: [{ target: source, clientX: 500, clientY: 500 }],
  }))
  expect(drops).not.toHaveBeenCalled()
})

test('touch preserves shared bundle artwork after the native drag image is removed', () => {
  source.className = 'bundle-source'
  const image = document.createElement('div')
  image.className = 'drag-bundle-image'
  image.textContent = '3 selected'
  registry.registerDragSource({ selector: '.bundle-source', onDragStart: ({ event }) => {
    event.dataTransfer.setData('test', JSON.stringify({ kind: 'creative', ids: ['1', '2', '3'] }))
    event.dataTransfer.setDragImage(image, 24, 24)
  } })
  touch('touchstart')
  jest.advanceTimersByTime(400)
  image.remove()
  const proxy = document.querySelector('.touch-drag-proxy')
  expect(proxy.style.position).toBe('fixed')
  expect(proxy.querySelector('.drag-bundle-image').textContent).toBe('3 selected')
  expect(proxy.querySelector('.drag-bundle-image').style.top).toBe('0px')
  touch('touchend')
  expect(drops).toHaveBeenCalledWith(expect.objectContaining({ ids: ['1', '2', '3'] }))
})

test('nested sources serialize only the closest owner when registries share a root', () => {
  const ancestor = document.createElement('div')
  ancestor.className = 'ancestor'
  document.body.appendChild(ancestor)
  ancestor.appendChild(source)
  const onDragStart = jest.fn()
  const parentRegistry = createDragDropRegistry({ root: document })
  parentRegistry.registerDragSource({ selector: '.ancestor', onDragStart })
  try {
    touch('touchstart')
    jest.advanceTimersByTime(400)
    touch('touchend')
    expect(onDragStart).not.toHaveBeenCalled()
    expect(drops).toHaveBeenCalledTimes(1)
  } finally { parentRegistry.destroy() }
})

test('a null browser hit cannot drop on an offscreen padded rectangle', () => {
  document.elementFromPoint = () => null
  touch('touchstart')
  jest.advanceTimersByTime(400)
  touch('touchend')
  expect(drops).not.toHaveBeenCalled()
})

test('the closest drop zone wins across registries with the same root', () => {
  const nested = document.createElement('div')
  nested.className = 'inner-zone'
  nested.getBoundingClientRect = zone.getBoundingClientRect
  zone.appendChild(nested)
  document.elementFromPoint = () => nested
  const onDrop = jest.fn()
  const nestedRegistry = createDragDropRegistry({ root: document,
    getKind: dt => dt.types.includes('test') ? 'creative' : null,
    readData: dt => JSON.parse(dt.getData('test')) })
  nestedRegistry.registerDropZone({ selector: '.inner-zone', accepts: ['creative'], onDrop })
  try {
    touch('touchstart')
    jest.advanceTimersByTime(400)
    touch('touchend')
    expect(onDrop).toHaveBeenCalledTimes(1)
    expect(drops).not.toHaveBeenCalled()
  } finally { nestedRegistry.destroy() }
})

test('a removed tap target cannot receive a stale click', () => {
  const click = jest.fn()
  source.addEventListener('click', click)
  touch('touchstart')
  source.remove()
  document.documentElement.dispatchEvent(new TouchEvent('touchend', { bubbles: true, cancelable: true }))
  expect(click).not.toHaveBeenCalled()
})

test('an overlay appearing during drop revalidation cancels the commit', () => {
  touch('touchstart')
  jest.advanceTimersByTime(400)
  document.elementFromPoint = jest.fn().mockReturnValueOnce(zone).mockReturnValue(source)
  touch('touchend')
  expect(drops).not.toHaveBeenCalled()
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
})

test('non-cancel keys do not interrupt a touch drag', () => {
  touch('touchstart')
  jest.advanceTimersByTime(400)
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab' }))
  touch('touchend')
  expect(drops).toHaveBeenCalledTimes(1)
})

test('live targets include a registered root and exclude another document', () => {
  const foreignDocument = document.implementation.createHTMLDocument('Other pane')
  foreignDocument.body.innerHTML = '<div class="foreign"></div>'
  const foreign = createDragDropRegistry({ root: foreignDocument, touch: false })
  foreign.registerDropZone({ selector: '.foreign', accepts: ['creative'], onDrop: jest.fn() })
  const local = createDragDropRegistry({ root: zone, touch: false })
  local.registerDropZone({ selector: '.zone', accepts: ['creative'], onDrop: jest.fn() })
  try {
    expect(local.localDropTargets()).toEqual([zone])
    expect(registry.getDropTargets()).toEqual([zone])
  } finally { local.destroy(); foreign.destroy() }
})

test('normal swipes retain native scrolling and never start a delayed drag', () => {
  expect(touch('touchstart', 50).defaultPrevented).toBe(false)
  expect(touch('touchmove', 55).defaultPrevented).toBe(false)
  expect(touch('touchmove', 80).defaultPrevented).toBe(false)
  jest.advanceTimersByTime(500)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
  expect(touch('touchend').defaultPrevented).toBe(false)
  expect(drops).not.toHaveBeenCalled()
})

test('committed long presses suppress native movement and the compatibility click', () => {
  const click = jest.fn()
  source.addEventListener('click', click)
  expect(touch('touchstart').defaultPrevented).toBe(false)
  jest.advanceTimersByTime(400)
  expect(touch('touchmove', 55).defaultPrevented).toBe(true)
  expect(touch('touchend').defaultPrevented).toBe(true)
  expect(click).not.toHaveBeenCalled()
  expect(drops).toHaveBeenCalledTimes(1)
})
