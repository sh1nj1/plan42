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

  // The readers default to T1's public envelope functions, so only a root that
  // cannot deliver events or an explicitly broken reader is a construction error.
  test('rejects a construction that cannot deliver events or read a payload', () => {
    registry = null
    expect(() => createDragDropRegistry({ root: {} })).toThrow(/event root/)
    expect(() => createDragDropRegistry({ root, getKind: null })).toThrow(/getKind/)
    expect(() => createDragDropRegistry({ root, readData: null })).toThrow(/readData/)
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

  test('rejects incomplete source and zone registrations', () => {
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })

    expect(() => registry.registerDragSource({ selector: '.source' })).toThrow(TypeError)
    expect(() => registry.registerDropZone({ selector: '.zone', accepts: 'creative' })).toThrow(TypeError)
    expect(() => createDragDropRegistry({ root: null })).toThrow(TypeError)
    expect(() => createDragDropRegistry({ root, getKind: 'nope' })).toThrow(TypeError)
    expect(() => createDragDropRegistry({ root, readData: 'nope' })).toThrow(TypeError)
  })

  test('unregistering a source stops it from claiming later drags', () => {
    const onDragStart = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })
    const unregister = registry.registerDragSource({ selector: '.source', onDragStart })
    const source = root.querySelector('.source')

    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    unregister()
    unregister()
    source.dispatchEvent(dragEvent('dragstart', source, transfer()))

    expect(onDragStart).toHaveBeenCalledTimes(1)
  })

  // A zone that cannot measure itself must not swallow the drag: the kernel
  // reports and steps aside so nothing is left highlighted.
  test('a throwing hitTest clears the preview and reports once', () => {
    const onError = jest.fn()
    const cleanup = jest.fn()
    let hitTest = () => 'child'
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null, onError })
    registry.registerDropZone({
      selector: '.zone', accepts: 'creative', hitTest: (...args) => hitTest(...args), preview: () => cleanup, onDrop: jest.fn(),
    })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    hitTest = () => { throw new Error('layout unavailable') }
    const second = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(second)

    expect(second.defaultPrevented).toBe(false)
    expect(cleanup).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'layout unavailable' }))
  })

  test('reports failures raised by preview, its cleanup, dragend, and drop reads', () => {
    const onError = jest.fn()
    registry = createDragDropRegistry({
      root,
      getKind: () => 'creative',
      readData: () => { throw new Error('unreadable transfer') },
      onError,
    })
    registry.registerDragSource({
      selector: '.source', onDragStart: jest.fn(), onDragEnd: () => { throw new Error('broken end') },
    })
    let hit = 'up'
    registry.registerDropZone({
      selector: '.zone',
      accepts: (kind) => kind === 'creative',
      hitTest: () => hit,
      preview: () => { throw new Error('broken preview') },
      onDrop: jest.fn(),
    })
    const zone = root.querySelector('.zone')
    const source = root.querySelector('.source')

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))
    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    source.dispatchEvent(dragEvent('dragend', source, transfer()))

    expect(onError.mock.calls.map(([error]) => error.message)).toEqual([
      'broken preview', 'unreadable transfer', 'broken end',
    ])
  })

  test('a cleanup failure is reported and never escapes the kernel', () => {
    const onError = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null, onError })
    let hit = 'up'
    registry.registerDropZone({
      selector: '.zone',
      accepts: 'creative',
      hitTest: () => hit,
      preview: () => () => { throw new Error('broken cleanup') },
      onDrop: jest.fn(),
    })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    hit = 'down'
    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))

    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: 'broken cleanup' }))
  })

  test('falls back to console when no reporter is supplied and the reporter itself fails', () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })
    registry.registerDragSource({ selector: '.source', onDragStart: () => { throw new Error('default reporter') } })
    const source = root.querySelector('.source')
    source.dispatchEvent(dragEvent('dragstart', source, transfer()))
    registry.destroy()

    registry = createDragDropRegistry({
      root, getKind: () => null, readData: () => null, onError: () => { throw new Error('reporter down') },
    })
    registry.registerDragSource({ selector: '.source', onDragStart: () => { throw new Error('source down') } })
    source.dispatchEvent(dragEvent('dragstart', source, transfer()))

    expect(consoleError.mock.calls.map(([error]) => error.message)).toEqual(['default reporter', 'reporter down'])
    consoleError.mockRestore()
  })

  test('keeps the preview while the pointer moves inside the active zone', () => {
    const cleanup = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null })
    registry.registerDropZone({
      selector: '.zone', accepts: 'creative', preview: () => cleanup, onDrop: jest.fn(), dropEffect: 'copy',
    })
    const zone = root.querySelector('.zone')
    const zoneChild = root.querySelector('.zone-child')
    const dataTransfer = transfer()

    zone.dispatchEvent(dragEvent('dragover', zone, dataTransfer))
    expect(dataTransfer.dropEffect).toBe('copy')
    zone.dispatchEvent(dragEvent('dragleave', zone, dataTransfer, { relatedTarget: zoneChild }))
    expect(cleanup).not.toHaveBeenCalled()

    zone.dispatchEvent(dragEvent('dragleave', zone, dataTransfer, { relatedTarget: root }))
    expect(cleanup).toHaveBeenCalledTimes(1)
    zone.dispatchEvent(dragEvent('dragleave', zone, dataTransfer))
    expect(cleanup).toHaveBeenCalledTimes(1)
  })

  test('ignores events outside the registry root and unmatched selectors', () => {
    const outside = document.createElement('div')
    outside.className = 'zone'
    document.body.appendChild(outside)
    const onDrop = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop })

    root.dispatchEvent(dragEvent('drop', outside, transfer()))
    root.dispatchEvent(dragEvent('drop', root, transfer()))
    root.dispatchEvent(dragEvent('dragstart', root, transfer()))
    root.dispatchEvent(dragEvent('dragend', root, transfer()))

    expect(onDrop).not.toHaveBeenCalled()
  })

  test('a document-rooted registry serves zones anywhere in the page', () => {
    const onDrop = jest.fn()
    registry = createDragDropRegistry({ getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('drop', zone, transfer()))

    expect(onDrop).toHaveBeenCalledTimes(1)
  })

  test('declines drags with no readable kind', () => {
    const onDrop = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => null, readData: () => null })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop })
    const zone = root.querySelector('.zone')

    const over = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(over)

    expect(over.defaultPrevented).toBe(false)
    expect(onDrop).not.toHaveBeenCalled()
  })

  test('an outer zone registered last never steals an inner match', () => {
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) })
    const innerDrop = jest.fn()
    const outerDrop = jest.fn()
    registry.registerDropZone({ selector: '.zone-child', accepts: 'creative', onDrop: innerDrop })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop: outerDrop })
    const child = root.querySelector('.zone-child')

    child.dispatchEvent(dragEvent('drop', child, transfer()))

    expect(innerDrop).toHaveBeenCalledTimes(1)
    expect(outerDrop).not.toHaveBeenCalled()
  })

  test('a hitTest that finds no position leaves the drag unhandled', () => {
    const onDrop = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', hitTest: () => null, onDrop })
    const zone = root.querySelector('.zone')

    const over = dragEvent('dragover', zone, transfer())
    zone.dispatchEvent(over)
    zone.dispatchEvent(dragEvent('drop', zone, transfer()))

    expect(over.defaultPrevented).toBe(false)
    expect(onDrop).not.toHaveBeenCalled()
  })

  test('a computed drop effect sees the resolved hit', () => {
    const dropEffect = jest.fn(() => 'link')
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', hitTest: () => 'child', dropEffect, onDrop: jest.fn() })
    const zone = root.querySelector('.zone')
    const dataTransfer = transfer()

    zone.dispatchEvent(dragEvent('dragover', zone, dataTransfer))

    expect(dataTransfer.dropEffect).toBe('link')
    expect(dropEffect).toHaveBeenCalledWith(expect.objectContaining({ hit: 'child', kind: 'creative' }))
  })

  test('unregistering an idle zone leaves an unrelated active preview alone', () => {
    const cleanup = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative', readData: () => null })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', preview: () => cleanup, onDrop: jest.fn() })
    const unregisterIdle = registry.registerDropZone({ selector: '.source', accepts: 'creative', onDrop: jest.fn() })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('dragover', zone, transfer()))
    unregisterIdle()
    unregisterIdle()

    expect(cleanup).not.toHaveBeenCalled()
  })

  test('defaults every option when constructed bare', () => {
    registry = createDragDropRegistry()
    const onDrop = jest.fn()
    registry.registerDropZone({ selector: '.zone', accepts: 'context', onDrop })
    const zone = root.querySelector('.zone')

    zone.dispatchEvent(dragEvent('drop', zone, { types: ['application/x-context-id'], getData: () => '7' }))

    expect(onDrop).toHaveBeenCalledWith(expect.objectContaining({ kind: 'context', ids: ['7'] }))
  })
  test('Escape cleans a native drag while other keys keep the preview', () => {
    const cleanup = jest.fn()
    const end = jest.fn()
    registry = createDragDropRegistry({ root, getKind: () => 'creative' })
    registry.registerDragSource({ selector: '.source', onDragStart: jest.fn(), onDragEnd: end })
    registry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop: jest.fn(), preview: () => cleanup })
    root.dispatchEvent(dragEvent('dragstart', root.querySelector('.source'), transfer()))
    root.dispatchEvent(dragEvent('dragover', root.querySelector('.zone'), transfer()))
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    expect(cleanup).not.toHaveBeenCalled()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(cleanup).toHaveBeenCalledTimes(1)
    expect(end).toHaveBeenCalledTimes(1)
  })

  test.each([true, false])('the nearest source and drop zone own overlapping registries (outer first: %s)', (outerFirst) => {
    const options = { getKind: () => 'creative', readData: () => ({ kind: 'creative', ids: ['1'], payload: {} }) }
    let outer
    let inner
    const makeOuter = () => { outer = createDragDropRegistry({ root: document, ...options }) }
    const makeInner = () => { inner = createDragDropRegistry({ root, ...options }) }
    if (outerFirst) { makeOuter(); makeInner() } else { makeInner(); makeOuter() }
    const outerStart = jest.fn()
    const innerStart = jest.fn()
    const outerDrop = jest.fn()
    const innerDrop = jest.fn()
    outer.registerDragSource({ selector: '#root', onDragStart: outerStart })
    outer.registerDropZone({ selector: '#root', accepts: 'creative', onDrop: outerDrop })
    inner.registerDragSource({ selector: '.source', onDragStart: innerStart })
    inner.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop: innerDrop })
    try {
      root.querySelector('.source').dispatchEvent(dragEvent('dragstart', root.querySelector('.source'), transfer()))
      root.querySelector('.zone').dispatchEvent(dragEvent('dragover', root.querySelector('.zone'), transfer()))
      root.querySelector('.zone').dispatchEvent(dragEvent('drop', root.querySelector('.zone'), transfer()))
      expect(innerStart).toHaveBeenCalledTimes(1)
      expect(outerStart).not.toHaveBeenCalled()
      expect(innerDrop).toHaveBeenCalledTimes(1)
      expect(outerDrop).not.toHaveBeenCalled()
    } finally { outer.destroy(); inner.destroy() }
  })

  test('a source can decline a native drag before it starts', () => {
    registry = createDragDropRegistry({ root })
    registry.registerDragSource({ selector: '.source', onDragStart: () => false })
    const event = dragEvent('dragstart', root.querySelector('.source'), transfer())
    root.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  })

})

test('gesture fallback remains document-local and is cleared by source removal', () => {
  document.body.innerHTML = '<div class="source"></div><div class="zone"></div>'
  const foreignDocument = document.implementation.createHTMLDocument('foreign')
  foreignDocument.body.innerHTML = '<div class="zone"></div>'
  const sourceRegistry = createDragDropRegistry({ root: document, touch: false })
  const foreignRegistry = createDragDropRegistry({ root: foreignDocument, touch: false })
  const onDrop = jest.fn()
  const data = { kind: 'creative', ids: ['1'], payload: { creativeId: '1', treeId: 'tree-1' } }
  const unregister = sourceRegistry.registerDragSource({ selector: '.source',
    onDragStart: ({ setLocalData }) => setLocalData(data) })
  foreignRegistry.registerDropZone({ selector: '.zone', accepts: 'creative', onDrop })
  try {
    const transfer = { types: [], getData: () => '' }
    const source = document.querySelector('.source')
    source.dispatchEvent(dragEvent('dragstart', source, transfer))
    expect(sourceRegistry.gestureData(document)).toEqual(data)
    expect(sourceRegistry.gestureData(foreignDocument)).toBeNull()
    const target = foreignDocument.querySelector('.zone')
    target.dispatchEvent(dragEvent('drop', target, transfer))
    expect(onDrop).not.toHaveBeenCalled()
    unregister()
    expect(sourceRegistry.gestureData(document)).toBeUndefined()
  } finally {
    foreignRegistry.destroy()
    sourceRegistry.destroy()
  }
})

test('touch cancels a source that provides neither serialized nor local data', () => {
  jest.useFakeTimers()
  document.body.innerHTML = '<div class="source"></div>'
  const registry = createDragDropRegistry()
  registry.registerDragSource({ selector: '.source', onDragStart: () => {} })
  try {
    const source = document.querySelector('.source')
    const point = { target: source, clientX: 10, clientY: 10 }
    source.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true,
      touches: [point], changedTouches: [point] }))
    jest.advanceTimersByTime(400)
    expect(registry.gestureData(document)).toBeUndefined()
    expect(document.querySelector('.touch-drag-proxy')).toBeNull()
    source.dispatchEvent(dragEvent('dragover', source, null))
    source.dispatchEvent(dragEvent('dragover', source, {}))
  } finally {
    registry.destroy()
    jest.useRealTimers()
  }
})
