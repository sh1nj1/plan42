/** @jest-environment jsdom */
import { recoverFailedCreative } from '../failed_creative_save'

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
