/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { createDragDropRegistry } from '../registry'

function transfer(kind = 'creative') {
  return {
    kind,
    dropEffect: 'none',
    types: [`application/x-${kind}`],
  }
}

function dragEvent(type, target, dataTransfer, options = {}) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.defineProperties(event, {
    target: { value: target },
    dataTransfer: { value: dataTransfer },
    relatedTarget: { value: options.relatedTarget || null },
  })
  return event
}

describe('createDragDropRegistry', () => {
  let root
  let registry

  beforeEach(() => {
    document.body.innerHTML = `
      <main id="root">
        <div class="source"><span class="source-child"></span></div>
        <div class="zone"><span class="zone-child"></span></div>
      </main>
    `
    root = document.getElementById('root')
  })

  afterEach(() => registry?.destroy())

  test('delegates source start and end for dynamically matched descendants', () => {
    const onDragStart = jest.fn()
    const onDragEnd = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })
    registry.registerDragSource({ selector: '.source', onDragStart, onDragEnd })

    const dataTransfer = transfer()
    root.querySelector('.source-child').dispatchEvent(dragEvent('dragstart', root.querySelector('.source-child'), dataTransfer))
    root.querySelector('.source-child').dispatchEvent(dragEvent('dragend', root.querySelector('.source-child'), dataTransfer))

    expect(onDragStart).toHaveBeenCalledWith(expect.objectContaining({ el: root.querySelector('.source') }))
    expect(onDragEnd).toHaveBeenCalledWith(expect.objectContaining({ el: root.querySelector('.source') }))
  })

  test('accepts a kind, previews one stable hit, and drops normalized data', () => {
    const previewCleanup = jest.fn()
    const preview = jest.fn(() => previewCleanup)
    const onDrop = jest.fn()
    registry = createDragDropRegistry({
      root,
      getKind: (dataTransfer) => dataTransfer.kind,
      readData: () => ({ kind: 'creative', ids: ['7'], payload: { source: 'right' } }),
    })
    registry.registerDropZone({
      selector: '.zone',
      accepts: ['creative'],
      hitTest: () => 'child',
      preview,
      onDrop,
    })

    const zoneChild = root.querySelector('.zone-child')
    const dataTransfer = transfer()
    const firstOver = dragEvent('dragover', zoneChild, dataTransfer)
    zoneChild.dispatchEvent(firstOver)
    zoneChild.dispatchEvent(dragEvent('dragover', zoneChild, dataTransfer))
    zoneChild.dispatchEvent(dragEvent('drop', zoneChild, dataTransfer))

    expect(firstOver.defaultPrevented).toBe(true)
    expect(dataTransfer.dropEffect).toBe('move')
    expect(preview).toHaveBeenCalledTimes(1)
    expect(previewCleanup).toHaveBeenCalledTimes(1)
    expect(onDrop).toHaveBeenCalledWith(expect.objectContaining({
      el: root.querySelector('.zone'),
      hit: 'child',
      kind: 'creative',
      ids: ['7'],
      payload: { source: 'right' },
    }))
  })

  test('cleans the previous preview when the hit changes', () => {
    const cleanups = [jest.fn(), jest.fn()]
    const preview = jest.fn(() => cleanups[preview.mock.calls.length - 1])
    let hit = 'up'
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null })
    registry.registerDropZone({
      selector: '.zone', accepts: 'creative', hitTest: () => hit, preview, onDrop: jest.fn(),
    })

    const zone = root.querySelector('.zone')
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    hit = 'down'
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))

    expect(cleanups[0]).toHaveBeenCalledTimes(1)
    expect(preview).toHaveBeenCalledTimes(2)
  })

  test('ignores rejected kinds and malformed drop data', () => {
    const onDrop = jest.fn()
    registry = createDragDropRegistry({
      root,
      getKind: (dataTransfer) => dataTransfer.kind,
      readData: () => null,
    })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop })
    const zone = root.querySelector('.zone')

    const topicOver = dragEvent('dragover', zone, transfer('topic'))
    zone.dispatchEvent(topicOver)
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))

    expect(topicOver.defaultPrevented).toBe(false)
    expect(onDrop).not.toHaveBeenCalled()
  })

  test('reports handler errors without breaking later drags and destroy detaches listeners', () => {
    const onError = jest.fn()
    const onDragStart = jest.fn(() => { throw new Error('broken source') })
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null, onError })
    registry.registerDragSource({ selector: '.source', onDragStart })
    const source = root.querySelector('.source')

    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken source' }))

    registry.destroy()
    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    expect(onDragStart).toHaveBeenCalledTimes(1)
    registry = null
  })
  test('defaults to the T1 public readers and does not read payload during dragover', () => {
    const getData = jest.fn(() => '7')
    registry = createDragDropRegistry({ root })
    const onDrop = jest.fn()
    registry.registerDropZone({ selector: '.zone', accepts: 'context', onDrop })
    const zone = root.querySelector('.zone')
    const data = { types: ['application/x-context-id'], getData }
    zone.dispatchEvent(dragEvent('dragover', zone, data))
    expect(getData).not.toHaveBeenCalled()
    zone.dispatchEvent(dragEvent('drop', zone, data))
    expect(onDrop).toHaveBeenCalledWith(expect.objectContaining({ kind: 'context', ids: ['7'], payload: {} }))
  })

  test('nested zones choose the closest match regardless of registration order', () => {
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) })
    const outerDrop = jest.fn()
    const innerDrop = jest.fn()
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop: outerDrop })
    registry.registerDropZone({ selector: '.zone-child', accepts: 'creative', onDrop: innerDrop })
    const child = root.querySelector('.zone-child')
    child.dispatchEvent(dragEvent('drop', child, transfer()))
    expect(innerDrop).toHaveBeenCalledTimes(1)
    expect(outerDrop).not.toHaveBeenCalled()
  })

  test('drop consumes the displayed intent and preserves prior hit for hysteresis', () => {
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) })
    const hitTest = jest.fn().mockReturnValueOnce('up').mockReturnValueOnce('child')
    const onDrop = jest.fn()
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', hitTest, onDrop })
    const zone = root.querySelector('.zone')
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    expect(hitTest.mock.calls[1][0].previousHit).toBe('up')
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))
    expect(hitTest).toHaveBeenCalledTimes(2)
    expect(onDrop.mock.calls[0][0].hit).toBe('child')
  })

  test('async drop rejection reports the error and clears preview', async () => {
    const onError = jest.fn()
    const cleanup = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }), onError })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', preview: () => cleanup, onDrop: async () => { throw new Error('offline') } })
    const zone = root.querySelector('.zone')
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))
    await Promise.resolve()
    expect(cleanup).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'offline' }))
  })

  test('unregistering the active zone clears its preview immediately', () => {
    const cleanup = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null })
    const unregister = registry.registerDropZone({ selector: '.zone', accepts: 'creative', preview: () => cleanup, onDrop: jest.fn() })
    const zone = root.querySelector('.zone')
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    unregister()
    expect(cleanup).toHaveBeenCalledTimes(1)
    expect(dragEvent('drop', zone, transfer()).defaultPrevented).toBe(false)
  })
})
