/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

const fakeTurbo = { StreamActions: {} }

jest.unstable_mockModule('@hotwired/turbo-rails', () => ({ Turbo: fakeTurbo }))
jest.unstable_mockModule('../../creatives/tree_renderer', () => ({
  createRow: jest.fn(),
  applyRowProperties: jest.fn(),
}))

await import('../turbo_stream_actions')

function dispatchCreativeTreeStream(payload) {
  fakeTurbo.StreamActions.refresh_creative_tree.call({
    getAttribute: (name) => name === 'data' ? JSON.stringify(payload) : null,
  })
}

afterEach(() => {
  document.body.innerHTML = ''
  jest.restoreAllMocks()
})

test('remote destroyed streams notify chat even when no tree row is visible', () => {
  const destroyedEvents = []
  const invalidatedEvents = []
  document.addEventListener('creative-destroyed', (event) => destroyedEvents.push(event.detail), { once: true })
  document.addEventListener('workspace-tree:invalidate', (event) => invalidatedEvents.push(event), { once: true })

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: { id: 123, linked_id: 456, parent_id: 42 },
  })

  expect(destroyedEvents).toEqual([{ creativeIds: ['456', '123'] }])
  expect(invalidatedEvents).toHaveLength(1)
})

test('remote destroyed streams deduplicate identical effective and origin IDs', () => {
  const listener = jest.fn()
  document.addEventListener('creative-destroyed', listener, { once: true })

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: { id: 123 },
  })

  expect(listener).toHaveBeenCalledWith(expect.objectContaining({
    detail: { creativeIds: ['123'] },
  }))
})
