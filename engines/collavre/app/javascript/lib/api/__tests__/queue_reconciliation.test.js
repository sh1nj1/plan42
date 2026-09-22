/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { recordRestoredCompletion, needsCreativeReconciliation, fetchReconciledCreative, clearQueueReconciliation } from '../queue_reconciliation'

test('invalidates restored completions per row instance and isolates users', async () => {
  const queue = { userId: 1 }
  const row = document.createElement('div')
  const item = { dedupeKey: 'creative_42' }
  recordRestoredCompletion(queue, {})
  recordRestoredCompletion(queue, { ...item, onSuccess: () => {} })
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(false)
  recordRestoredCompletion(queue, item)
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(true)
  expect(needsCreativeReconciliation(queue, 43, row)).toBe(false)
  const fetch = jest.fn().mockResolvedValue({ description: 'acknowledged' })
  expect(await fetchReconciledCreative(queue, 42, row, fetch)).toEqual({ description: 'acknowledged' })
  expect(fetch).toHaveBeenCalledWith(42)
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(false)
  expect(needsCreativeReconciliation(queue, 42, row.cloneNode())).toBe(true)
  recordRestoredCompletion(queue, { ...item, onSuccess: () => {} })
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(true)
  queue.userId = 2
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(false)
  recordRestoredCompletion(queue, item)
  clearQueueReconciliation(queue)
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(false)
})

test('retries reads overtaken by a completion and retains invalidation on read failure', async () => {
  const queue = {}
  const row = document.createElement('div')
  const item = { dedupeKey: 'creative_42' }
  const fetch = jest.fn().mockImplementationOnce(async () => {
    recordRestoredCompletion(queue, item)
    return { description: 'stale' }
  }).mockResolvedValue({ description: 'latest' })
  expect(await fetchReconciledCreative(queue, 42, row, fetch)).toEqual({ description: 'latest' })
  expect(fetch).toHaveBeenCalledTimes(2)
  recordRestoredCompletion(queue, item)
  await expect(fetchReconciledCreative(queue, 42, row, async () => { throw new Error('offline') })).rejects.toThrow('offline')
  expect(needsCreativeReconciliation(queue, 42, row)).toBe(true)
  await fetchReconciledCreative(queue, 42, null, fetch)
  await fetchReconciledCreative(queue, 43, row, fetch)
})
