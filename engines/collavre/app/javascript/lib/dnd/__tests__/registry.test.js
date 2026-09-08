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

  test('rejects a construction that cannot deliver events or read a payload', () => {
    registry = null
    expect(() => createDragDropRegistry()).toThrow(TypeError)
    expect(() => createDragDropRegistry({ root: {} })).toThrow(/event root/)
    expect(() => createDragDropRegistry({ root, readData: () => null })).toThrow(/getKind/)
    expect(() => createDragDropRegistry({ root, getKind: () => null })).toThrow(/readData/)
  })

  test('ignores elements matched outside the registry root', () => {
    document.body.innerHTML = `
      <div class="source"><main id="nested"><span class="inner"></span></main></div>
    `
    const nested = document.getElementById('nested')
    const onDragStart = jest.fn()
    registry = createDragDropRegistry({ root: nested, getKind: () => null, readData: () => null })
    registry.registerDragSource({ selector: '.source', onDragStart })

    const inner = nested.querySelector('.inner')
    inner.dispatchEvent(dragEvent('dragstart', inner, transfer()))

    expect(onDragStart).not.toHaveBeenCalled()
  })

  test('ignores a drag that starts outside every registered source', () => {
    const onDragStart = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })
    registry.registerDragSource({ selector: '.source', onDragStart })

    const zone = root.querySelector('.zone')
    zone.dispatchEvent(dragEvent('dragstart', zone, transfer()))

    expect(onDragStart).not.toHaveBeenCalled()
  })

  test('ignores a drag end that never started and reports a failing end handler', () => {
    const onError = jest.fn()
    const onDragEnd = jest.fn(() => { throw new Error('broken end') })
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null, onError })
    registry.registerDragSource({ selector: '.source', onDragStart: jest.fn(), onDragEnd })
    const source = root.querySelector('.source')

    source.dispatchEvent(dragEvent('dragend', source, transfer()))
    expect(onDragEnd).not.toHaveBeenCalled()

    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    source.dispatchEvent(dragEvent('dragend', source, transfer()))
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken end' }))
  })

  test('resolves acceptance through a predicate and skips a missing kind', () => {
    const accepts = jest.fn((kind) => kind === 'creative')
    const onDrop = jest.fn()
    let kind = null
    registry = createDragDropRegistry({
      root,
      getKind: () => kind,
      readData: () => ({ kind: 'creative', ids: ['1'] }),
    })
    registry.registerDropZone({ selector: '.zone', accepts, onDrop })
    const zone = root.querySelector('.zone')

    const withoutKind = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(withoutKind)
    expect(withoutKind.defaultPrevented).toBe(false)
    expect(accepts).not.toHaveBeenCalled()

    kind = 'creative'
    const withKind = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(withKind)
    expect(withKind.defaultPrevented).toBe(true)
    expect(accepts).toHaveBeenCalledWith('creative', expect.anything())
  })

  test('declines a zone whose hit test rejects the pointer position', () => {
    const onDrop = jest.fn()
    registry = createDragDropRegistry({
      root,
      getKind: () => 'creative',
      readData: () => ({ kind: 'creative', ids: ['1'] }),
    })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', hitTest: () => null, onDrop })
    const zone = root.querySelector('.zone')

    const over = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(over)
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))

    expect(over.defaultPrevented).toBe(false)
    expect(onDrop).not.toHaveBeenCalled()
  })

  test('drops the preview when resolution itself fails', () => {
    const onError = jest.fn()
    const previewCleanup = jest.fn()
    let failing = false
    registry = createDragDropRegistry({
      root,
      getKind: () => {
        if (failing) throw new Error('broken kind')
        return 'creative'
      },
      readData: () => null,
      onError,
    })
    registry.registerDropZone({
      selector: '.zone', accepts: 'creative', preview: () => previewCleanup, onDrop: jest.fn(),
    })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    failing = true
    const failed = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(failed)

    expect(failed.defaultPrevented).toBe(false)
    expect(previewCleanup).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken kind' }))
  })

  test('reports a failing preview, a failing cleanup, and a failing drop handler', async () => {
    const onError = jest.fn()
    let previewMode = 'throw'
    registry = createDragDropRegistry({
      root,
      getKind: () => 'creative',
      readData: () => ({ kind: 'creative', ids: ['1'] }),
      onError,
    })
    registry.registerDropZone({
      selector: '.zone',
      accepts: 'creative',
      hitTest: () => previewMode,
      preview: () => {
        if (previewMode === 'throw') throw new Error('broken preview')
        if (previewMode === 'cleanup') return () => { throw new Error('broken cleanup') }
        return undefined
      },
      onDrop: () => { throw new Error('broken drop') },
    })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken preview' }))

    previewMode = 'cleanup'
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    previewMode = 'plain'
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken cleanup' }))

    zone.dispatchEvent(dragEvent('drop', zone, transfer()))
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken drop' }))
  })

  test('falls back to the console when the error reporter itself fails', () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    const onError = jest.fn(() => { throw new Error('broken reporter') })
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null, onError })
    registry.registerDragSource({
      selector: '.source', onDragStart: () => { throw new Error('broken source') },
    })
    const source = root.querySelector('.source')

    source.dispatchEvent(dragEvent('dragstart', source, transfer()))

    expect(consoleError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken reporter' }))
    consoleError.mockRestore()
  })

  test('reports to the console when no error reporter is supplied', () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })
    registry.registerDragSource({
      selector: '.source', onDragStart: () => { throw new Error('unreported source') },
    })
    const source = root.querySelector('.source')

    source.dispatchEvent(dragEvent('dragstart', source, transfer()))

    expect(consoleError).toHaveBeenCalledWith(expect.objectContaining({ message: 'unreported source' }))
    consoleError.mockRestore()
  })

  test('keeps the preview while the pointer stays inside the active zone', () => {
    const previewCleanup = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null })
    registry.registerDropZone({
      selector: '.zone', accepts: 'creative', preview: () => previewCleanup, onDrop: jest.fn(),
    })
    const zone = root.querySelector('.zone')
    const zoneChild = root.querySelector('.zone-child')

    zone.dispatchEvent(dragEvent('dragleave', zone, transfer()))
    expect(previewCleanup).not.toHaveBeenCalled()

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    zone.dispatchEvent(dragEvent('dragleave', zone, transfer(), { relatedTarget: zoneChild }))
    expect(previewCleanup).not.toHaveBeenCalled()

    zone.dispatchEvent(dragEvent('dragleave', zone, transfer(), { relatedTarget: root.querySelector('.source') }))
    expect(previewCleanup).toHaveBeenCalledTimes(1)
  })

  test('ignores a drop that lands outside every registered zone', () => {
    const readData = jest.fn(() => ({ kind: 'creative', ids: ['1'] }))
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData })
    const zone = root.querySelector('.zone')

    const drop = dragEvent('drop', zone, transfer())
    zone.dispatchEvent(drop)

    expect(drop.defaultPrevented).toBe(false)
    expect(readData).not.toHaveBeenCalled()
  })

  test('rejects registrations that cannot participate in a drag', () => {
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })

    expect(() => registry.registerDragSource()).toThrow(/selector and onDragStart/)
    expect(() => registry.registerDragSource({ selector: '.source' })).toThrow(TypeError)
    expect(() => registry.registerDropZone({ accepts: 'creative', onDrop: jest.fn() })).toThrow(TypeError)
    expect(() => registry.registerDropZone({ selector: '.zone', onDrop: jest.fn() })).toThrow(TypeError)
    expect(() => registry.registerDropZone({ selector: '.zone', accepts: 'creative' })).toThrow(/selector, accepts, and onDrop/)
  })

  test('unregisters a source and a zone exactly once', () => {
    const onDragStart = jest.fn()
    const onDrop = jest.fn()
    registry = createDragDropRegistry({
      root,
      getKind: () => 'creative',
      readData: () => ({ kind: 'creative', ids: ['1'] }),
    })
    const unregisterSource = registry.registerDragSource({ selector: '.source', onDragStart })
    const unregisterZone = registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop })

    unregisterSource()
    unregisterSource()
    unregisterZone()
    unregisterZone()

    const source = root.querySelector('.source')
    const zone = root.querySelector('.zone')
    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))

    expect(onDragStart).not.toHaveBeenCalled()
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
})
