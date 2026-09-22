/** @jest-environment jsdom */
import { recoverFailedCreative, needsCreativeSaveRetry } from '../failed_creative_save'
import { unacknowledgedBody } from '../../lib/api/queue_recovery'

test('restores persisted failed fields over stale server data after reload', () => {
  const tree = document.createElement('div')
  const queue = {
    failedItems: [{ dedupeKey: 'creative_42' }],
    unacknowledgedBody: () => ({
      'creative[description]': '<p>draft</p>',
      'creative[content_type_input]': 'markdown',
      'creative[markdown_source]': 'draft',
      'creative[progress]': 1,
      before_id: '9',
    }),
  }
  expect(recoverFailedCreative(queue, { id: 42, description_raw_html: 'stale', progress: 0 }, tree)).toMatchObject({
    description_raw_html: '<p>draft</p>', content_type: 'markdown', markdown_source: 'draft', progress: 1,
  })
  expect(tree.dataset.saveState).toBe('error')
})

test('preserves server fields absent from a failed request and ignores other rows', () => {
  const data = { id: 42, description_raw_html: 'server', content_type: 'html' }
  const tree = document.createElement('div')
  expect(recoverFailedCreative({}, data, tree)).toBe(data)
  expect(recoverFailedCreative({ failedItems: [{ dedupeKey: 'creative_43' }] }, data, tree)).toBe(data)
  expect(recoverFailedCreative({ failedItems: [{ dedupeKey: 'creative_42' }], unacknowledgedBody: () => ({ 'creative[progress]': 1 }) }, data, tree)).toEqual({ ...data, progress: 1 })
})

test('merges failed, executing, and waiting snapshots in order and ignores unrelated rows', () => {
  const tree = document.createElement('div')
  const queue = {
    failedItems: [{ dedupeKey: 'creative_42', body: { 'creative[progress]': 1, 'creative[description]': 'failed' } }],
    queue: [
      { dedupeKey: 'creative_42', body: { 'creative[description]': 'executing' } },
      { dedupeKey: 'creative_42', body: { 'creative[description]': 'latest' } },
      { dedupeKey: 'creative_43', body: { 'creative[description]': 'unrelated' } },
    ],
  }
  queue.unacknowledgedBody = key => unacknowledgedBody(queue, key)
  expect(recoverFailedCreative(queue, { id: 42, progress: 0 }, tree)).toMatchObject({
    description_raw_html: 'latest', progress: 1,
  })
  expect(tree.dataset.saveState).toBe('error')
  queue.failedItems = []
  expect(recoverFailedCreative(queue, { id: 42 }, tree).description_raw_html).toBe('latest')
  expect(tree.dataset.saveState).toBe('pending')
  const other = { id: 44 }
  expect(recoverFailedCreative(queue, other, tree)).toBe(other)
})

test('only retries failed or restored requests without a live completion callback', () => {
  const tree = document.createElement('div')
  expect(needsCreativeSaveRetry({}, 42, tree)).toBe(false)
  const queue = { queue: [
    { dedupeKey: 'creative_43' },
    { dedupeKey: 'creative_42', onSuccess: () => {} },
  ] }
  expect(needsCreativeSaveRetry(queue, 42, tree)).toBe(false)
  delete queue.queue[1].onSuccess
  expect(needsCreativeSaveRetry(queue, 42, tree)).toBe(true)
  tree.dataset.saveState = 'error'
  expect(needsCreativeSaveRetry({}, 42, tree)).toBe(true)
})
