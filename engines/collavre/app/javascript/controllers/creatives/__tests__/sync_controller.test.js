/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const subscribeToCreatives = jest.fn()

jest.unstable_mockModule('../../../services/creatives_channel', () => ({
  subscribeToCreatives,
}))

const { Application } = await import('@hotwired/stimulus')
const SyncController = (await import('../sync_controller')).default

describe('CreativesSyncController subscribe timing', () => {
  let application
  let container

  beforeEach(() => {
    subscribeToCreatives.mockReset()
    subscribeToCreatives.mockReturnValue({
      cleanup: jest.fn(),
      sendEditing: jest.fn(),
      sendStoppedEditing: jest.fn(),
    })

    container = document.createElement('div')
    container.id = 'sync-root'
    container.setAttribute('data-controller', 'creatives--sync')
    container.setAttribute('data-creatives--sync-root-id-value', '991')
    document.body.appendChild(container)

    application = Application.start()
    application.register('creatives--sync', SyncController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  test('does NOT subscribe immediately when rootIdValue > 0 — waits for tree to load', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(subscribeToCreatives).not.toHaveBeenCalled()
  })

  test('subscribes after creative-tree:updated event fires', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(subscribeToCreatives).not.toHaveBeenCalled()

    container.dispatchEvent(
      new CustomEvent('creative-tree:updated', { bubbles: true }),
    )

    expect(subscribeToCreatives).toHaveBeenCalledTimes(1)
    expect(subscribeToCreatives).toHaveBeenCalledWith(991, expect.any(Object))
  })

  test('subscribes only once even if creative-tree:updated fires multiple times', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))

    container.dispatchEvent(new CustomEvent('creative-tree:updated', { bubbles: true }))
    container.dispatchEvent(new CustomEvent('creative-tree:updated', { bubbles: true }))
    container.dispatchEvent(new CustomEvent('creative-tree:updated', { bubbles: true }))

    expect(subscribeToCreatives).toHaveBeenCalledTimes(1)
  })

  test('subscribes immediately when tree is already loaded (Turbo cache restore)', async () => {
    // Simulate Turbo restoring a cached tree page: data-loaded is already set
    // before sync_controller connects, so tree_controller skips load() and
    // never dispatches creative-tree:updated.
    const cached = document.createElement('div')
    cached.id = 'sync-cached'
    cached.setAttribute('data-controller', 'creatives--cached-sync')
    cached.setAttribute('data-creatives--cached-sync-root-id-value', '991')
    cached.setAttribute('data-loaded', 'true')
    cached.innerHTML = '<creative-tree-row creative-id="1"></creative-tree-row>'
    document.body.appendChild(cached)

    application.register('creatives--cached-sync', SyncController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(subscribeToCreatives).toHaveBeenCalledTimes(1)
    expect(subscribeToCreatives).toHaveBeenCalledWith(991, expect.any(Object))
  })
})
