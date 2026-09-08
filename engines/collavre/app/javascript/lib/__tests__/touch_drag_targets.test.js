/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import TouchDragHandler from '../touch_drag'

let handler, container, onDrop, onCancel, onTargetChange
const rect = (top = 0) => ({ left: 0, right: 200, top, bottom: top + 100, width: 200, height: 100 })
function target(top = 0) {
  const el = document.createElement('div')
  el.className = 'drop-target'
  el.getBoundingClientRect = () => rect(top)
  document.body.appendChild(el)
  return el
}
function touch(type, x = 50, y = 50) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.defineProperty(event, 'touches', { value: type === 'touchend' || type === 'touchcancel'
    ? [] : [{ clientX: x, clientY: y, target: container }] })
  container.dispatchEvent(event)
  return event
}
function start(x = 50, y = 50) {
  touch('touchstart', x, y)
  jest.advanceTimersByTime(400)
}
function setup(options = {}) {
  handler = new TouchDragHandler({ container, singleElement: true, dropTargetSelector: '.drop-target',
    onDrop, onCancel, onTargetChange, ...options })
}
beforeEach(() => {
  jest.useFakeTimers()
  container = document.createElement('div')
  container.getBoundingClientRect = () => rect()
  document.body.appendChild(container)
  onDrop = jest.fn()
  onCancel = jest.fn()
  onTargetChange = jest.fn()
})
afterEach(() => {
  handler?.destroy()
  document.body.innerHTML = ''
  jest.useRealTimers()
})

test('reports hit changes inside one target and delivers position at drop', () => {
  const el = target()
  const hitTest = jest.fn((target, point) => point.clientY < 30 ? 'up' : 'child')
  setup({ hitTest })
  start(50, 20)
  touch('touchmove', 50, 60)
  expect(hitTest).toHaveBeenLastCalledWith(el, { clientX: 50, clientY: 60 }, 'up')
  expect(onTargetChange).toHaveBeenLastCalledWith(el, { clientX: 50, clientY: 60, hit: 'child' })
  touch('touchend')
  expect(onDrop).toHaveBeenCalledWith(el, { clientX: 50, clientY: 60, hit: 'child' })
  expect(el.classList.contains('drag-over')).toBe(false)
})

test('refresh discovers expanded targets and forgets removed targets without finger movement', () => {
  setup()
  start()
  const added = target()
  handler.refreshDropTargets()
  expect(added.classList.contains('drag-over')).toBe(true)
  added.remove()
  handler.refreshDropTargets()
  touch('touchend')
  expect(onDrop).not.toHaveBeenCalled()
  expect(onCancel).toHaveBeenCalledTimes(1)
})

test('rejects hidden and disallowed targets, resolving fresh candidate lists', () => {
  const hidden = target()
  hidden.getBoundingClientRect = () => ({ ...rect(), width: 0 })
  const rejected = target()
  const accepted = target()
  const getDropTargets = jest.fn(() => [hidden, rejected, accepted])
  setup({ getDropTargets, hitTest: el => el === rejected ? null : 'down' })
  start()
  touch('touchend')
  expect(onDrop).toHaveBeenCalledWith(accepted, expect.objectContaining({ hit: 'down' }))
})

test('touchcancel never commits a drop or triggers a pending tap', () => {
  target()
  const onTap = jest.fn()
  setup({ onTap })
  touch('touchstart')
  touch('touchcancel')
  expect(onTap).not.toHaveBeenCalled()
  start()
  touch('touchcancel')
  expect(onDrop).not.toHaveBeenCalled()
  expect(onCancel).toHaveBeenCalledTimes(1)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
})

test('autoscroll continues while stationary and stops on cancellation', () => {
  const el = target()
  const scrollContainer = jest.fn(() => container)
  setup({ autoScroll: true, scrollContainer })
  start(50, 95)
  jest.advanceTimersByTime(48)
  expect(container.scrollTop).toBeGreaterThan(0)
  expect(scrollContainer).toHaveBeenCalledWith({ clientX: 50, clientY: 95 }, el)
  touch('touchcancel')
  const stopped = container.scrollTop
  jest.advanceTimersByTime(100)
  expect(container.scrollTop).toBe(stopped)
  expect(jest.getTimerCount()).toBe(0)
})

test('autoscroll moves up near the top, stays still at the center and outside the pane', () => {
  setup({ autoScroll: true })
  container.scrollTop = 200
  start(50, 5)
  jest.advanceTimersByTime(32)
  expect(container.scrollTop).toBeLessThan(200)
  touch('touchmove', 50, 50)
  const centered = container.scrollTop
  jest.advanceTimersByTime(32)
  expect(container.scrollTop).toBe(centered)
  touch('touchmove', 250, 95)
  jest.advanceTimersByTime(32)
  expect(container.scrollTop).toBe(centered)
})

test('destroy clears active highlights, proxy and animation frames', () => {
  const el = target()
  setup({ autoScroll: true })
  start()
  handler.destroy()
  expect(el.classList.contains('drag-over')).toBe(false)
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
  expect(jest.getTimerCount()).toBe(0)
})
