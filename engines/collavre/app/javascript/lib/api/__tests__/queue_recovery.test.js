/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { unacknowledgedBody, unacknowledgedAttachmentIds, acknowledgeQueuedRequest } from '../queue_recovery'

test('merges only matching snapshots in failed, executing, then pending order', () => {
  const queue = {
    failedItems: [{ dedupeKey: 'a', body: { progress: 1, description: 'failed' } }],
    queue: [{ dedupeKey: 'other', body: { progress: 9 } }, { dedupeKey: 'a', body: { description: 'executing' } }, { dedupeKey: 'a', body: { description: 'pending' } }],
  }
  expect(unacknowledgedBody(queue, 'a')).toEqual({ progress: 1, description: 'pending' })
  expect(unacknowledgedBody(queue)).toEqual({})
})

test('acknowledgment clears only matching failures and persists the remaining entries', () => {
  const queue = { failedItems: [{ dedupeKey: 'a' }, { dedupeKey: 'b' }], saveFailedToLocalStorage: jest.fn() }
  acknowledgeQueuedRequest(queue, {})
  expect(queue.failedItems).toHaveLength(2)
  acknowledgeQueuedRequest(queue, { dedupeKey: 'a' })
  expect(queue.failedItems).toEqual([{ dedupeKey: 'b' }])
  expect(queue.saveFailedToLocalStorage).toHaveBeenCalledTimes(2)
})


test('cleanup recovery ignores absent keys and requests without cleanup', () => {
  const queue = { failedItems: [], queue: [{ dedupeKey: 'a' }] }
  expect(unacknowledgedAttachmentIds(queue)).toEqual([])
  expect(unacknowledgedAttachmentIds(queue, 'a')).toEqual([])
})
