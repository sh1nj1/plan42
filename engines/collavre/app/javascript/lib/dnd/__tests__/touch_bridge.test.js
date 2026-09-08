/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { createDragDropRegistry } from '../registry'
import { createTouchBridge } from '../touch_bridge'

let registry, bridge, source, zone, drops, previews
function touch(type, y = 50, target = source) {
  const event = new Event(type, { bubbles: true, cancelable: true })
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

test('a quick tap retains the original nested button action', () => {
  const button = document.createElement('button')
  source.appendChild(button)
  const click = jest.fn()
  button.addEventListener('click', click)
  touch('touchstart', 50, button)
  touch('touchend', 50, button)
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
