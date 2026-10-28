/** @jest-environment jsdom */
import { jest } from '@jest/globals'
const applyRowProperties = jest.fn()
jest.unstable_mockModule('../../creatives/tree_renderer', () => ({ applyRowProperties }))
const { applyPendingCreativeSyncData } = await import('../pending_creative_sync')
const { queuedCreativeCompletion, updateQueuedCreativeRow, queuedCreativeStatus, revealCreativeRow } = await import('../queued_creative_row')
const { waitForQueuedRequests, mergeQueueCallbacks } = await import('../../lib/api/queue_completion')

beforeEach(() => {
  document.body.innerHTML = ''
  jest.clearAllMocks()
})

test('applies deferred sync data, removes consumed data, and tolerates invalid payloads', async () => {
  document.body.innerHTML = '<creative-tree-row data-pending-sync-data=\'{"id":42}\'></creative-tree-row><creative-tree-row data-pending-sync-data="invalid"></creative-tree-row>'
  const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
  await applyPendingCreativeSyncData(document.body)
  expect(applyRowProperties).toHaveBeenCalledWith(document.body.firstElementChild, { id: 42 })
  expect(document.querySelectorAll('[data-pending-sync-data]')).toHaveLength(0)
  expect(warn).toHaveBeenCalledTimes(1)
  warn.mockRestore()
})

test('handles a detached row, HTML caches, and an absent status', () => {
  const tree = document.createElement('div')
  expect(queuedCreativeStatus()).toBe('')
  updateQueuedCreativeRow(tree, { content: 'no row' })
  expect(queuedCreativeCompletion(tree, jest.fn())()).toBe(true)
  document.body.innerHTML = '<creative-tree-row><div class="creative-tree"></div></creative-tree-row>'
  const attached = document.querySelector('.creative-tree')
  updateQueuedCreativeRow(attached, { content: '<p>html</p>', contentType: 'html' })
  expect(document.querySelector('creative-tree-row').dataset.markdownSource).toBe('')
  expect(document.querySelector('creative-tree-row').dataset.markdownEditor).toBe('')
})

test('reveals a hidden row painted from a non-empty buffer snapshot only', () => {
  document.body.innerHTML = '<creative-tree-row><div class="creative-tree"><div class="creative-row" style="display: none"></div></div></creative-tree-row>'
  const tree = document.querySelector('.creative-tree')
  const row = tree.querySelector('.creative-row')
  revealCreativeRow(tree, { content: '', emptyContent: '', emptyContentType: 'html' })
  expect(row.style.display).toBe('none')
  revealCreativeRow(tree, { content: '<p>typed</p>', emptyContent: '<p>typed</p>', emptyContentType: 'html', contentType: 'html' })
  expect(row.style.display).toBe('')
  expect(document.querySelector('creative-tree-row').dataset.descriptionHtml).toBe('<p>typed</p>')
  expect(() => revealCreativeRow(document.createElement('div'), { content: 'x' })).not.toThrow()
})

test('a dependent operation ignores failures and completions for other creatives', async () => {
  const manager = { queue: [{ dedupeKey: 'creative_42' }] }
  const settled = jest.fn()
  const promise = waitForQueuedRequests(manager, 'creative_42').then(settled)
  window.dispatchEvent(new CustomEvent('api-queue-request-failed', { detail: { item: { dedupeKey: 'creative_43' } } }))
  window.dispatchEvent(new CustomEvent('api-queue-request-completed'))
  await Promise.resolve()
  expect(settled).not.toHaveBeenCalled()
  manager.queue = []
  window.dispatchEvent(new CustomEvent('api-queue-request-completed'))
  await promise
  expect(settled).toHaveBeenCalledTimes(1)
})


test('a failed callback cannot prevent later callbacks from acknowledging the save', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {})
  const next = jest.fn()
  mergeQueueCallbacks([() => { throw new Error('callback failure') }], next)({ id: 42 })
  expect(next).toHaveBeenCalledWith({ id: 42 })
  expect(error).toHaveBeenCalledTimes(1)
  error.mockRestore()
})
