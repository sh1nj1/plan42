import { jest } from '@jest/globals'
import { createDragDropRegistry } from '../registry.js'

let registry, root, readData, onError, cleanup, onDrop
const transfer = () => ({ types: ['application/x-collavre-creative'], dropEffect: 'none' })
function dispatch(type, el = root.querySelector('.inner'), properties = {}) {
  const event = new window.Event(type, { bubbles: true, cancelable: true })
  Object.assign(event, { dataTransfer: transfer(), ...properties })
  el.dispatchEvent(event)
  return event
}
function zone(options = {}) {
  return registry.registerDropZone({ selector: '.outer', accepts: ['creative'], onDrop,
    preview: () => cleanup, ...options })
}
beforeEach(() => {
  document.body.innerHTML = '<div id="root"><div class="outer"><span class="inner">Row</span></div></div>'
  root = document.querySelector('#root')
  readData = jest.fn(() => ({ kind: 'creative', ids: ['1'] }))
  onError = jest.fn()
  cleanup = jest.fn()
  onDrop = jest.fn()
  registry = createDragDropRegistry({ root, readData, onError,
    getKind: dt => dt.types.includes('application/x-collavre-creative') ? 'creative' : null })
})
afterEach(() => registry.destroy())

test('uses visible types during dragover and reads payload only on drop', () => {
  zone()
  const event = dispatch('dragover')
  expect(event.defaultPrevented).toBe(true)
  expect(event.dataTransfer.dropEffect).toBe('move')
  expect(readData).not.toHaveBeenCalled()
  dispatch('drop')
  expect(readData).toHaveBeenCalledTimes(1)
  expect(onDrop).toHaveBeenCalledWith(expect.objectContaining({ kind: 'creative', ids: ['1'], hit: 'into' }))
  expect(cleanup).toHaveBeenCalledTimes(1)
})

test('picks nearest supported nested zone independent of registration order', () => {
  zone()
  const nested = jest.fn()
  zone({ selector: '.inner', onDrop: nested })
  dispatch('drop')
  expect(nested).toHaveBeenCalledTimes(1)
  expect(onDrop).not.toHaveBeenCalled()
})

test('ignores unsupported types and incompatible zones', () => {
  zone({ accepts: ['topic'] })
  expect(dispatch('dragover').defaultPrevented).toBe(false)
  expect(dispatch('drop', undefined, { dataTransfer: { types: ['text/plain'] } }).defaultPrevented).toBe(false)
  expect(readData).not.toHaveBeenCalled()
})

test('rejects invalid hit without falling through to ancestor zones', () => {
  zone()
  zone({ selector: '.inner', hitTest: () => null })
  expect(dispatch('dragover').defaultPrevented).toBe(false)
  dispatch('drop')
  expect(onDrop).not.toHaveBeenCalled()
})

test('rejects absent or mismatched decoded payload', () => {
  zone()
  readData.mockReturnValueOnce(null).mockReturnValueOnce({ kind: 'topic', ids: ['1'] })
  dispatch('drop')
  dispatch('drop')
  expect(onDrop).not.toHaveBeenCalled()
})

test('delegation survives row replacement and accepts text node event targets', () => {
  zone()
  root.innerHTML = '<div class="outer">New row</div>'
  dispatch('drop', root.firstChild.firstChild)
  expect(onDrop).toHaveBeenCalledTimes(1)
})

test('preview persists inside zone and cleans when moving outside or changing hit', () => {
  let hit = 'up'
  const preview = jest.fn(() => cleanup)
  zone({ hitTest: () => hit, preview, dropEffect: 'copy' })
  expect(dispatch('dragover').dataTransfer.dropEffect).toBe('copy')
  dispatch('dragover')
  dispatch('dragleave', undefined, { relatedTarget: root.querySelector('.outer') })
  expect(preview).toHaveBeenCalledTimes(1)
  expect(cleanup).not.toHaveBeenCalled()
  hit = 'child'
  dispatch('dragover')
  expect(cleanup).toHaveBeenCalledTimes(1)
  dispatch('dragover', root)
  expect(cleanup).toHaveBeenCalledTimes(2)
  dispatch('dragover')
  dispatch('dragleave', undefined, { relatedTarget: null })
  expect(cleanup).toHaveBeenCalledTimes(3)
})

test('unregistration and destruction remove previews and listeners', () => {
  const unregister = zone()
  dispatch('dragover')
  unregister()
  expect(cleanup).toHaveBeenCalledTimes(1)
  expect(dispatch('dragover').defaultPrevented).toBe(false)
  zone()
  dispatch('dragover')
  registry.destroy()
  expect(cleanup).toHaveBeenCalledTimes(2)
  dispatch('drop')
  expect(onDrop).not.toHaveBeenCalled()
})

test('source lifecycle handles cancellation, outside dragend and unregister', () => {
  const onDragStart = jest.fn()
  const onDragEnd = jest.fn()
  const unregister = registry.registerDragSource({ selector: '.inner', onDragStart, onDragEnd })
  zone()
  dispatch('dragstart')
  dispatch('dragover')
  dispatch('keydown', document.body, { key: 'ArrowDown' })
  expect(onDragEnd).not.toHaveBeenCalled()
  dispatch('keydown', document.body, { key: 'Escape' })
  expect(onDragEnd).toHaveBeenCalledTimes(1)
  expect(cleanup).toHaveBeenCalledTimes(1)
  dispatch('dragstart')
  dispatch('dragend', document.body)
  expect(onDragEnd).toHaveBeenCalledTimes(2)
  dispatch('dragstart')
  unregister()
  expect(onDragEnd).toHaveBeenCalledTimes(3)
  dispatch('dragstart')
  expect(onDragStart).toHaveBeenCalledTimes(3)
})

test('source can reject a start and unsupported source is ignored', () => {
  const onDragEnd = jest.fn()
  registry.registerDragSource({ selector: '.inner', onDragStart: () => false, onDragEnd })
  dispatch('dragstart', root)
  dispatch('dragstart')
  dispatch('dragend')
  expect(onDragEnd).not.toHaveBeenCalled()
})

test('handles async and synchronous failures and always removes preview', async () => {
  const error = new Error('failed command')
  zone({ onDrop: () => Promise.reject(error) })
  dispatch('dragover')
  dispatch('drop')
  await Promise.resolve()
  expect(onError).toHaveBeenCalledWith(error)
  expect(cleanup).toHaveBeenCalledTimes(1)
  readData.mockImplementation(() => { throw error })
  dispatch('dragover')
  dispatch('drop')
  expect(onError).toHaveBeenCalledTimes(2)
  expect(cleanup).toHaveBeenCalledTimes(2)
})

test('document roots and optional callbacks work without a preview', () => {
  registry.destroy()
  registry = createDragDropRegistry({ root: document, getKind: () => 'creative', readData })
  const unregisterSource = registry.registerDragSource({ selector: '.inner', onDragStart: () => {} })
  const unregisterZone = registry.registerDropZone({ selector: '.outer', accepts: ['creative'], onDrop })
  dispatch('dragstart')
  dispatch('dragend')
  unregisterSource()
  unregisterZone()
})

test('touch discovery combines live zones and tracks changing DOM and teardown', () => {
  const other = createDragDropRegistry({ root: document, getKind: () => null, readData })
  registry.registerDragSource({ selector: '.inner', onDragStart: () => {} })
  expect(registry.getDragSource(root.querySelector('.inner'))).toBe(root.querySelector('.inner'))
  expect(registry.getDragSource(root)).toBeNull()
  expect(other.getDropTargets()).toEqual([])
  zone()
  other.registerDropZone({ selector: '#root', accepts: ['creative'], onDrop })
  expect(registry.getDropTargets()).toEqual([root.querySelector('.outer'), root])
  const unregister = registry.registerDropZone({ selector: '#root', accepts: ['creative'], onDrop })
  expect(registry.getDropTargets()).toHaveLength(2)
  unregister()
  root.innerHTML = '<div class="outer">replacement</div>'
  expect(registry.getDropTargets()[0]).toBe(root.firstChild)
  other.destroy()
  expect(registry.getDropTargets()).toEqual([root.firstChild])
})

test.each([true, false])('one nearest registry owns a drop with shared root=%s regardless of listener order', sharedRoot => {
  zone()
  const nestedDrop = jest.fn(() => root.querySelector('.inner').classList.remove('inner'))
  const other = createDragDropRegistry({ root: sharedRoot ? root : root.querySelector('.outer'),
    getKind: () => 'creative', readData })
  other.registerDropZone({ selector: '.inner', accepts: ['creative'], onDrop: nestedDrop })
  expect(dispatch('dragover').defaultPrevented).toBe(true)
  dispatch('drop')
  expect(nestedDrop).toHaveBeenCalledTimes(1)
  expect(onDrop).not.toHaveBeenCalled()
  other.destroy()
})

test('an invalid inner registry target blocks the ancestor registry', () => {
  zone()
  const other = createDragDropRegistry({ root, getKind: () => 'creative', readData })
  other.registerDropZone({ selector: '.inner', accepts: ['creative'], hitTest: () => null, onDrop })
  expect(dispatch('dragover').defaultPrevented).toBe(false)
  dispatch('drop')
  expect(onDrop).not.toHaveBeenCalled()
  other.destroy()
})
