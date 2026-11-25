/** @jest-environment jsdom */
import { jest } from '@jest/globals'
const applyRowProperties = jest.fn()
jest.unstable_mockModule('../../creatives/tree_renderer', () => ({ applyRowProperties }))
const applySavedProgress = jest.fn()
jest.unstable_mockModule('../../creatives/row_progress', () => ({ applySavedProgress }))
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

test('completion refreshes a row that missed a broadcast once and releases without requesting a refetch', () => {
  document.body.innerHTML = '<creative-tree-row data-missed-sync="true" data-pending-sync-data="{}"><div class="creative-tree"></div></creative-tree-row>'
  const tree = document.querySelector('.creative-tree')
  const row = document.querySelector('creative-tree-row')
  const refetch = jest.fn()
  const release = jest.fn()
  document.addEventListener('creative-sync:refetch', refetch)
  document.addEventListener('creative-sync:release', release)
  const refreshMissed = jest.fn()

  expect(queuedCreativeCompletion(tree, jest.fn(), refreshMissed)()).toBe(true)
  expect(queuedCreativeCompletion(tree, jest.fn(), refreshMissed)()).toBe(true)
  document.removeEventListener('creative-sync:refetch', refetch)
  document.removeEventListener('creative-sync:release', release)

  expect(refreshMissed).toHaveBeenCalledTimes(1)
  expect(refreshMissed).toHaveBeenCalledWith(tree)
  expect(row.dataset.missedSync).toBeUndefined()
  expect(row.dataset.pendingSyncData).toBeUndefined()
  expect(release).toHaveBeenCalledTimes(2)
  expect(refetch).not.toHaveBeenCalled()
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

test('only the latest completion applies the progress its response carries', () => {
  document.body.innerHTML = '<creative-tree-row><div class="creative-tree"></div></creative-tree-row>'
  const tree = document.querySelector('.creative-tree')
  const row = document.querySelector('creative-tree-row')
  const superseded = queuedCreativeCompletion(tree, jest.fn(), jest.fn())
  const latest = queuedCreativeCompletion(tree, jest.fn(), jest.fn())
  const saved = { progress: 1, progress_html: '<done>', ancestors: [{ id: 1, progress: 0.5 }] }

  expect(superseded({ progress: 0 })).toBe(false)
  expect(applySavedProgress).not.toHaveBeenCalled()
  expect(latest(saved)).toBe(true)
  expect(applySavedProgress).toHaveBeenCalledTimes(1)
  expect(applySavedProgress).toHaveBeenCalledWith(row, saved)
})
