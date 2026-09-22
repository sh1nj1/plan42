/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

let editorOptions = null
const save = jest.fn()
const get = jest.fn(() => Promise.resolve({}))
const enqueue = jest.fn()
const unconvert = jest.fn()
const waitFor = jest.fn(() => Promise.resolve())
const alertDialog = jest.fn()
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  alertDialog,
  confirmDialog: jest.fn(() => Promise.resolve(true)),
}))

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: jest.fn((_container, options) => {
    editorOptions = options
    return {
      destroy: jest.fn(),
      load: jest.fn(),
      focus: jest.fn(),
      reset: jest.fn(),
      getDeletedAttachments: jest.fn(() => []),
    }
  }),
}))
jest.unstable_mockModule('../creative_row_editor_delegated_clicks', () => ({
  createDelegatedClickHandler: jest.fn(() => jest.fn()),
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    save,
    unconvert,
    get,
    loadChildren: jest.fn(() => Promise.resolve({ creatives: [] })),
  },
}))
const queue = {
  initialize: jest.fn(), start: jest.fn(), enqueue, waitFor,
  failedItems: [], unacknowledgedBody: jest.fn(),
}
jest.unstable_mockModule('../../lib/api/queue_manager', () => ({ default: queue }))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')
const {
  appendExistingRow, buildEditorDom, defineTreeRowStub, flush,
} = await import('./support/inline_editor_dom')

function response(data = {}) {
  return Promise.resolve({
    ok: true,
    text: () => Promise.resolve(JSON.stringify(data)),
  })
}

function openRow(tree) {
  document.dispatchEvent(new CustomEvent('creative-edit-click', {
    detail: { treeElement: tree },
  }))
}

async function flushPromises() {
  for (let i = 0; i < 10; i += 1) await Promise.resolve()
}

function appendMarkdownRow(id, source, editor = 'source') {
  const result = appendExistingRow(id)
  result.rowComponent.dataset.contentType = 'markdown'
  result.rowComponent.dataset.markdownSource = source
  result.rowComponent.dataset.markdownEditor = editor
  result.rowComponent.dataset.descriptionRawHtml = `<p>${source}</p>`
  return result
}

beforeAll(() => defineTreeRowStub())

beforeEach(() => {
  document.body.innerHTML = '<div id="creatives"></div><div id="center-frame"></div>'
  buildEditorDom(document.getElementById('center-frame'))
  save.mockReset()
  get.mockReset().mockResolvedValue({})
  enqueue.mockReset()
  queue.failedItems = []
  queue.queue = []
  queue.unacknowledgedBody.mockReset()
  unconvert.mockReset()
  waitFor.mockReset().mockResolvedValue()
  alertDialog.mockClear()
  save.mockImplementation(() => response())
  const form = document.getElementById('inline-edit-form-element')
  const typeRoot = document.createElement('div')
  typeRoot.dataset.creativeTypeEditor = ''
  typeRoot.dataset.options = JSON.stringify([{ name: 'General', value: '' }, { name: 'Workflow', value: 'workflow' }])
  typeRoot.dataset.addLabel = 'Add %{name}'
  typeRoot.innerHTML = '<input id="type" role="combobox"><input type="hidden" name="creative[creative_type]" disabled><div class="common-popup" style="display:none"><ul></ul></div><button type="button">Cancel</button><span role="alert"></span><a hidden>Rules</a>'
  form.appendChild(typeRoot)
  window.HTMLElement.prototype.scrollIntoView = jest.fn()
  initializeCreativeRowEditor()
  document.getElementById('metadata-popup').style.display = 'none'
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
  editorOptions = null
})

test('progress save queues a serializable snapshot and applies a server rewrite', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before')
  openRow(tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'draft ![image](data:old)'
  textarea.dispatchEvent(new Event('input'))
  const progress = document.getElementById('inline-creative-progress')
  progress.checked = true
  progress.dispatchEvent(new Event('change'))
  await flushPromises()
  expect(save).not.toHaveBeenCalled()
  const queued = enqueue.mock.calls[0][0]
  expect(queued.body['creative[markdown_source]']).toBe('draft ![image](data:old)')
  expect(queued.body['creative[progress]']).toBe(1)
  expect(tree.dataset.saveState).toBe('pending')
  queued.onSuccess({ markdown_source: 'draft ![image](/blob/image.png)' })
  expect(textarea.value).toBe('draft ![image](/blob/image.png)')
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(enqueue).toHaveBeenCalledTimes(1)
})

test('persistent queue snapshots the outgoing row, keeps its object body, applies response data, and clears dirty state', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before', 'rich')
  const second = appendMarkdownRow('43', 'second', 'rich')
  openRow(first.tree)

  editorOptions.onChange({ html: '<p>outgoing edit</p>', markdown: 'outgoing edit' })
  document.getElementById('inline-move-down').click()
  await flushPromises()

  expect(enqueue).toHaveBeenCalledTimes(1)
  const queued = enqueue.mock.calls[0][0]
  expect(queued.path).toBe('/creatives/42')
  expect(queued.method).toBe('PATCH')
  expect(queued.body).toEqual(expect.objectContaining({
    'creative[description]': '<p>outgoing edit</p>',
    'creative[content_type_input]': 'markdown',
    'creative[markdown_source]': 'outgoing edit',
    'creative[markdown_editor]': 'rich',
  }))
  expect(queued.body).not.toBeInstanceOf(FormData)
  expect(document.getElementById('inline-edit-form-element').dataset.creativeId).toBe('43')

  queued.onSuccess({ markdown_source: 'server rewrite' })
  expect(first.rowComponent.dataset.markdownSource).toBe('server rewrite')

  document.getElementById('inline-move-up').click()
  await Promise.resolve()
  document.getElementById('inline-move-down').click()
  await Promise.resolve()
  expect(enqueue).toHaveBeenCalledTimes(1)
  expect(second.rowComponent.dataset.markdownSource).toBe('second')
})

test('direct save skips an empty buffer', async () => {
  const { rowComponent, tree } = appendExistingRow('42')
  rowComponent.dataset.descriptionRawHtml = ''
  openRow(tree)

  const progress = document.getElementById('inline-creative-progress')
  progress.checked = true
  progress.dispatchEvent(new Event('change'))
  await Promise.resolve()

  expect(save).not.toHaveBeenCalled()
})

test('persistent queue skips an empty buffer', async () => {
  const first = appendExistingRow('42')
  first.rowComponent.dataset.descriptionRawHtml = ''
  appendExistingRow('43')
  openRow(first.tree)

  editorOptions.onChange({ html: '', markdown: '' })
  document.getElementById('inline-move-down').click()
  await flushPromises()

  expect(enqueue).not.toHaveBeenCalled()
})

test('persistent queue carries an unacknowledged progress toggle into the body and row dataset', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before', 'rich')
  appendMarkdownRow('43', 'second', 'rich')
  openRow(first.tree)

  // The checkbox queues immediately; moving must not enqueue the same edit again.
  editorOptions.onChange({ html: '<p>outgoing edit</p>', markdown: 'outgoing edit' })
  const progress = document.getElementById('inline-creative-progress')
  progress.checked = true
  progress.dispatchEvent(new Event('change'))
  await Promise.resolve()

  document.getElementById('inline-move-down').click()
  await flushPromises()

  expect(enqueue).toHaveBeenCalledTimes(1)
  expect(enqueue.mock.calls[0][0].body['creative[progress]']).toBe(1)
  expect(first.rowComponent.dataset.progressValue).toBe('1')

  enqueue.mock.calls[0][0].onSuccess({})
  await flushPromises()
})

test('queued response rewrites the live textarea when the row is reopened before the ack', async () => {
  jest.useFakeTimers()
  const dataUri = 'data:image/png;base64,abc123'
  const first = appendMarkdownRow('42', `before ${dataUri}`)
  appendMarkdownRow('43', 'second')
  openRow(first.tree)

  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = `draft ${dataUri}`
  textarea.dispatchEvent(new Event('input'))

  document.getElementById('inline-move-down').click()
  await flushPromises()
  expect(enqueue).toHaveBeenCalledTimes(1)
  const queued = enqueue.mock.calls[0][0]

  // Back on the same row before the queued PATCH is acknowledged.
  document.getElementById('inline-move-up').click()
  await flushPromises()
  expect(document.getElementById('inline-edit-form-element').dataset.creativeId).toBe('42')

  queued.onSuccess({ markdown_source: 'draft /blob/image.png' })

  expect(textarea.value).toBe('draft /blob/image.png')
  expect(document.getElementById('inline-markdown-source').value).toBe('draft /blob/image.png')
  expect(first.rowComponent.dataset.markdownSource).toBe('draft /blob/image.png')

  // The rewrite also moved the dirty baseline (originalContent), so simply
  // reopening and leaving the row must not queue a second save.
  enqueue.mockClear()
  document.getElementById('inline-move-down').click()
  await flushPromises()
  expect(enqueue).not.toHaveBeenCalled()
})

function selectType(name) {
  const input = document.getElementById('type')
  input.focus()
  input.value = name
  input.dispatchEvent(new Event('input'))
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
}

test('failed type and body save prevents navigation until repaired', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  appendMarkdownRow('43', 'next')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'Keep my draft'
  textarea.dispatchEvent(new Event('input'))
  selectType('Workflow')
  save.mockResolvedValue({ ok: false, clone: () => ({ json: async () => ({ errors: ['Admin required'] }) }) })
  document.getElementById('inline-move-down').click()
  await flushPromises()
  await jest.advanceTimersByTimeAsync(0)
  expect(document.querySelector('[role=alert]').textContent).toBe('Admin required')
  expect(textarea.value).toBe('Keep my draft')
  expect(document.getElementById('inline-edit-form-element').dataset.creativeId).toBe('42')
  expect(enqueue).not.toHaveBeenCalled()
  selectType('General')
  save.mockImplementation(() => response({ id: 42, creative_type: '' }))
  document.getElementById('inline-close').click()
  await flushPromises()
  await jest.advanceTimersByTimeAsync(0)
  expect(document.getElementById('inline-edit-form').style.display).toBe('none')
})

test.each(['inline-add', 'inline-level-down'])('%s flushes type and body before a new row', async button => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  openRow(first.tree)
  selectType('Workflow')
  let submitted
  save.mockImplementation((_path, _method, form) => {
    submitted = new FormData(form)
    return response({ id: 42, creative_type: 'workflow' })
  })
  if (button === 'inline-add') document.getElementById(button).click()
  else editorOptions.onKeyDown({ key: 'Enter', altKey: true, preventDefault: jest.fn() }, {})
  await flushPromises()
  expect(submitted.get('creative[creative_type]')).toBe('workflow')
  expect(submitted.get('creative[markdown_source]')).toBe('before')
})


test('combined body and type acknowledgment clears pending status', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before', 'rich')
  openRow(tree)
  const status = document.getElementById('inline-save-status')
  status.dataset.labelSaved = 'Saved'
  status.dataset.labelPending = 'Pending'
  editorOptions.onChange({ html: '<p>edited</p>', markdown: 'edited' })
  selectType('Workflow')
  save.mockImplementation(() => response({ id: 42, creative_type: 'workflow' }))
  await jest.advanceTimersByTimeAsync(5000)
  expect(status.textContent).toBe('Saved')
})


test('closing after a failed autosave retries the retained type instead of discarding it', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before')
  openRow(tree)
  selectType('Workflow')
  save.mockResolvedValue({ ok: false, clone: () => ({ json: async () => ({ errors: ['Denied'] }) }) })
  await jest.advanceTimersByTimeAsync(5000)
  expect(save).toHaveBeenCalledTimes(1)
  document.getElementById('inline-close').click()
  await jest.advanceTimersByTimeAsync(0)
  expect(save).toHaveBeenCalledTimes(2)
  expect(document.getElementById('inline-edit-form').style.display).toBe('block')
  expect(document.getElementById('type').value).toBe('Workflow')
})

async function openEmptyRow() {
  const { tree } = appendMarkdownRow('42', 'before')
  openRow(tree)
  document.getElementById('inline-add').click()
  await jest.advanceTimersByTimeAsync(20)
  save.mockClear()
}

test('canceling a type on a new empty row before debounce creates no creative', async () => {
  jest.useFakeTimers()
  await openEmptyRow()
  selectType('Workflow')
  document.querySelector('[data-creative-type-editor] button').click()
  await jest.advanceTimersByTimeAsync(5000)
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(save).not.toHaveBeenCalled()
  expect(enqueue).not.toHaveBeenCalled()
})

test('canceling a type preserves independent body edits on a new row', async () => {
  jest.useFakeTimers()
  await openEmptyRow()
  editorOptions.onChange({ html: '<p>Keep this draft</p>', markdown: 'Keep this draft' })
  selectType('Workflow')
  document.querySelector('[data-creative-type-editor] button').click()
  let submitted
  save.mockImplementation((_path, _method, form) => {
    submitted = new FormData(form)
    return response({ id: 44, creative_type: '' })
  })
  await jest.advanceTimersByTimeAsync(5000)
  expect(save).toHaveBeenCalledTimes(1)
  expect(submitted.get('creative[markdown_source]')).toBe('Keep this draft')
  expect(submitted.has('creative[creative_type]')).toBe(false)
})

test('cancel during an in-flight type save persists the restored type after acknowledgment', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before')
  openRow(tree)
  let settle
  const submitted = []
  save.mockImplementation((_path, _method, form) => {
    submitted.push(new FormData(form).get('creative[creative_type]'))
    if (submitted.length === 1) return new Promise(resolve => { settle = resolve })
    return response({ id: 42, creative_type: '' })
  })
  selectType('Workflow')
  await jest.advanceTimersByTimeAsync(5000)
  document.querySelector('[data-creative-type-editor] button').click()
  settle({ ok: true, text: async () => JSON.stringify({ id: 42, creative_type: 'workflow' }) })
  await jest.advanceTimersByTimeAsync(5000)
  expect(submitted).toEqual(['workflow', ''])
  expect(document.getElementById('type').value).toBe('General')
})


test('cancel during a failed in-flight save keeps the body and restored type for retry', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before')
  openRow(tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'Retain this body'
  textarea.dispatchEvent(new Event('input'))
  let settle
  save.mockImplementation(() => new Promise(resolve => { settle = resolve }))
  selectType('Workflow')
  await jest.advanceTimersByTimeAsync(5000)
  document.querySelector('[data-creative-type-editor] button').click()
  settle({ ok: false, clone: () => ({ json: async () => ({ errors: ['Denied'] }) }) })
  await flushPromises()
  expect(document.getElementById('type').value).toBe('General')
  expect(textarea.value).toBe('Retain this body')
  let submitted
  save.mockImplementation((_path, _method, form) => {
    submitted = new FormData(form)
    return response({ id: 42, creative_type: '' })
  })
  document.getElementById('inline-close').click()
  await jest.advanceTimersByTimeAsync(0)
  expect(submitted.get('creative[creative_type]')).toBe('')
  expect(submitted.get('creative[markdown_source]')).toBe('Retain this body')
  expect(document.getElementById('inline-edit-form').style.display).toBe('none')
})


test.each(['inline-close', 'inline-move-down', 'inline-add'])('%s releases the editor before server acknowledgment', async button => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  appendMarkdownRow('43', 'next')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'Local draft'
  textarea.dispatchEvent(new Event('input'))
  document.getElementById(button).click()
  await jest.advanceTimersByTimeAsync(20)
  expect(save).not.toHaveBeenCalled()
  expect(enqueue).toHaveBeenCalledTimes(1)
  expect(first.rowComponent.dataset.markdownSource).toBe('Local draft')
  expect(first.tree.dataset.saveState).toBe('pending')
  if (button === 'inline-close') expect(document.getElementById('inline-edit-form').style.display).toBe('none')
  else expect(document.getElementById('inline-edit-form-element').dataset.creativeId).not.toBe('42')
})

test('autosave queues edits and ignores an older acknowledgment after another save', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'first'
  textarea.dispatchEvent(new Event('input'))
  await jest.advanceTimersByTimeAsync(5000)
  textarea.value = 'second'
  textarea.dispatchEvent(new Event('input'))
  await jest.advanceTimersByTimeAsync(5000)
  expect(enqueue).toHaveBeenCalledTimes(2)
  enqueue.mock.calls[0][0].onSuccess({ markdown_source: 'obsolete server rewrite' })
  expect(textarea.value).toBe('second')
  expect(first.tree.dataset.saveState).toBe('pending')
  enqueue.mock.calls[1][0].onSuccess({ markdown_source: 'second' })
  expect(document.getElementById('inline-save-status').dataset.state).toBe('saved')
  expect(save).not.toHaveBeenCalled()
})

test('reopening an unacknowledged row preserves pending status and the local body', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'offline draft'
  textarea.dispatchEvent(new Event('input'))
  document.getElementById('inline-close').click()
  await flushPromises()
  openRow(first.tree)
  await flushPromises()
  expect(textarea.value).toBe('offline draft')
  expect(document.getElementById('inline-save-status').dataset.state).toBe('pending')
})

test.each(['inline-close', 'inline-move-down'])('%s keeps the editor and draft when local persistence fails', async button => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  appendMarkdownRow('43', 'next')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'Retain this draft'
  textarea.dispatchEvent(new Event('input'))
  enqueue.mockImplementation(() => { throw new Error('quota') })
  document.getElementById(button).click()
  await flushPromises()
  expect(textarea.value).toBe('Retain this draft')
  expect(document.getElementById('inline-edit-form-element').dataset.creativeId).toBe('42')
  expect(document.getElementById('inline-edit-form').style.display).toBe('block')
  expect(document.getElementById('inline-save-status').dataset.state).toBe('error')
})


test('a storage failure restores the previous queued acknowledgment without losing the newer draft', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'first queued draft'
  textarea.dispatchEvent(new Event('input'))
  await jest.advanceTimersByTimeAsync(5000)
  const firstRequest = enqueue.mock.calls[0][0]
  textarea.value = 'newer retained draft'
  textarea.dispatchEvent(new Event('input'))
  enqueue.mockImplementationOnce(() => { throw new Error('quota') })
  await jest.advanceTimersByTimeAsync(5000)
  expect(first.tree.dataset.saveState).toBe('error')
  firstRequest.onSuccess({ markdown_source: 'first queued draft' })
  expect(first.tree.dataset.saveState).toBeUndefined()
  expect(textarea.value).toBe('newer retained draft')
  expect(document.getElementById('inline-save-status').dataset.state).toBe('pending')
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(enqueue.mock.calls[2][0].body['creative[markdown_source]']).toBe('newer retained draft')
})


test.each(['42', '123'])('permanent failure marks only failed row %s and preserves it on reopen', async failedId => {
  jest.useFakeTimers()
  const current = appendMarkdownRow('42', 'current draft')
  const other = appendMarkdownRow('123', 'other draft')
  openRow(current.tree)
  const log = jest.spyOn(console, 'error').mockImplementation(() => {})
  window.dispatchEvent(new CustomEvent('api-queue-request-failed', {
    detail: { item: { path: `/creatives/${failedId}`, method: 'PATCH' }, error: { status: 404 } },
  }))
  const failed = failedId === '42' ? current : other
  const untouched = failedId === '42' ? other : current
  expect(failed.tree.dataset.saveState).toBe('error')
  expect(untouched.tree.dataset.saveState).toBeUndefined()
  if (failedId === '42') {
    expect(document.getElementById('inline-save-status').dataset.state).toBe('error')
    document.getElementById('inline-close').click()
    await flushPromises()
    expect(enqueue).toHaveBeenCalledTimes(1)
    expect(enqueue.mock.calls[0][0].body['creative[markdown_source]']).toBe('current draft')
  } else {
    openRow(other.tree)
    await flushPromises()
    expect(document.getElementById('inline-save-status').dataset.state).toBe('error')
  }
  log.mockRestore()
})

test('unconvert waits for queued and direct saves before changing the linked creative', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before')
  tree.dataset.parentId = '7'
  tree.closest('creative-tree-row').dataset.parentId = '7'
  openRow(tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'queued draft'
  textarea.dispatchEvent(new Event('input'))
  await jest.advanceTimersByTimeAsync(5000)
  let releaseQueue, releaseSave
  waitFor.mockImplementationOnce(() => new Promise(resolve => { releaseQueue = resolve }))
  save.mockImplementationOnce(() => new Promise(resolve => { releaseSave = resolve }))
  unconvert.mockResolvedValue({ ok: false, json: async () => ({ error: 'Cannot unconvert' }) })
  document.getElementById('inline-unconvert').click()
  await jest.advanceTimersByTimeAsync(0)
  expect(waitFor).toHaveBeenCalledWith('creative_42')
  expect(save).not.toHaveBeenCalled()
  expect(unconvert).not.toHaveBeenCalled()
  releaseQueue()
  await jest.advanceTimersByTimeAsync(0)
  expect(save).toHaveBeenCalledTimes(1)
  expect(unconvert).not.toHaveBeenCalled()
  releaseSave(await response())
  await jest.advanceTimersByTimeAsync(0)
  expect(unconvert).toHaveBeenCalledWith('42')
  expect(alertDialog).toHaveBeenCalledWith('Cannot unconvert')
  expect(document.getElementById('inline-unconvert').disabled).toBe(false)
})

test('unconvert stops when the preceding save fails', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'retained draft')
  tree.dataset.parentId = '7'
  tree.closest('creative-tree-row').dataset.parentId = '7'
  openRow(tree)
  save.mockResolvedValue({ ok: false, clone: () => ({ json: async () => ({ error: 'Save denied' }) }), json: async () => ({ error: 'Save denied' }) })
  document.getElementById('inline-unconvert').click()
  await jest.advanceTimersByTimeAsync(0)
  expect(unconvert).not.toHaveBeenCalled()
  expect(alertDialog).toHaveBeenCalledWith('Save denied')
  expect(document.getElementById('inline-unconvert').disabled).toBe(false)
})

test('reopening a row that failed while closed retries its draft without another edit', async () => {
  const first = appendMarkdownRow('42', 'before')
  appendMarkdownRow('43', 'second')
  openRow(first.tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'failed draft'
  textarea.dispatchEvent(new Event('input'))
  document.getElementById('inline-move-down').click()
  await flushPromises()
  const request = enqueue.mock.calls[0][0]
  window.dispatchEvent(new CustomEvent('api-queue-request-failed', {
    detail: { item: request, error: new Error('offline') },
  }))
  expect(first.tree.dataset.saveState).toBe('error')
  openRow(first.tree)
  await flushPromises()
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(enqueue).toHaveBeenCalledTimes(2)
  const retry = enqueue.mock.calls[1][0]
  expect(retry.body['creative[markdown_source]']).toBe('failed draft')
  retry.onSuccess({})
  expect(first.tree.dataset.saveState).toBeUndefined()
})

test('reopening after reload restores the persisted failed draft over server data and retries it', async () => {
  queue.failedItems = [{ dedupeKey: 'creative_42' }]
  queue.unacknowledgedBody.mockReturnValue({
    'creative[description]': '<p>persisted draft</p>',
    'creative[content_type_input]': 'markdown',
    'creative[markdown_source]': 'persisted draft',
    'creative[markdown_editor]': 'source',
    'creative[progress]': 1,
  })
  const { tree } = appendMarkdownRow('42', 'stale server')
  openRow(tree)
  expect(document.getElementById('markdown-editor-textarea').value).toBe('persisted draft')
  expect(document.getElementById('inline-creative-progress').checked).toBe(true)
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(enqueue).toHaveBeenCalledTimes(1)
  expect(enqueue.mock.calls[0][0].body['creative[markdown_source]']).toBe('persisted draft')
  enqueue.mock.calls[0][0].onSuccess({})
  expect(tree.dataset.saveState).toBeUndefined()
})

function restoreFailedProgressDraft() {
  const body = {
    'creative[description]': '<p>recovered draft</p>',
    'creative[content_type_input]': 'markdown',
    'creative[markdown_source]': 'recovered draft',
    'creative[progress]': 1,
  }
  queue.failedItems = [{ dedupeKey: 'creative_42', body }]
  queue.unacknowledgedBody.mockReturnValue(body)
  const { tree } = appendMarkdownRow('42', 'stale server')
  tree.dataset.parentId = '7'
  tree.closest('creative-tree-row').dataset.parentId = '7'
  openRow(tree)
  return tree
}

test('type change acknowledges recovered progress and clears the failed draft before direct save', async () => {
  jest.useFakeTimers()
  const { unacknowledgedBody, clearAcknowledgedFailures } = await import('../../lib/api/queue_recovery')
  const tree = restoreFailedProgressDraft()
  queue.queue = []
  queue.saveFailedToLocalStorage = jest.fn()
  enqueue.mockImplementation(request => {
    queue.queue.push({ ...request, body: { ...unacknowledgedBody(queue, request.dedupeKey), ...request.body } })
  })
  let acknowledge
  waitFor.mockImplementationOnce(() => new Promise(resolve => { acknowledge = resolve }))
  selectType('Workflow')
  await jest.advanceTimersByTimeAsync(5000)
  expect(save).not.toHaveBeenCalled()
  expect(queue.queue[0].body['creative[progress]']).toBe(1)
  expect(queue.queue[0].body['creative[markdown_source]']).toBe('recovered draft')
  const request = queue.queue.shift()
  request.onSuccess({})
  clearAcknowledgedFailures(queue, request)
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'newer body'
  textarea.dispatchEvent(new Event('input'))
  save.mockImplementation((_path, _method, form) => {
    expect(new FormData(form).get('creative[markdown_source]')).toBe('newer body')
    return response({ id: 42, creative_type: 'workflow' })
  })
  get.mockResolvedValue({ id: 42, content_type: 'markdown', markdown_source: 'newer body', markdown_editor: 'source', description: '<p>newer body</p>', progress: 1, creative_type: 'workflow' })
  acknowledge()
  await jest.advanceTimersByTimeAsync(0)
  expect(save).toHaveBeenCalledTimes(1)
  expect(queue.failedItems).toEqual([])
  expect(queue.saveFailedToLocalStorage).toHaveBeenCalled()
  document.getElementById('inline-close').click()
  await jest.advanceTimersByTimeAsync(0)
  openRow(tree)
  await jest.advanceTimersByTimeAsync(0)
  expect(textarea.value).toBe('newer body')
})

test.each(['type', 'unconvert'])('%s stops if the recovered draft retry fails', async action => {
  jest.useFakeTimers()
  restoreFailedProgressDraft()
  let rejectRetry
  waitFor.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectRetry = reject }))
  if (action === 'type') {
    selectType('Workflow')
    document.getElementById('inline-close').click()
  } else document.getElementById('inline-unconvert').click()
  await jest.advanceTimersByTimeAsync(0)
  expect(enqueue).toHaveBeenCalledTimes(1)
  expect(save).not.toHaveBeenCalled()
  expect(unconvert).not.toHaveBeenCalled()
  rejectRetry(new Error('Retry denied'))
  await jest.advanceTimersByTimeAsync(0)
  expect(save).not.toHaveBeenCalled()
  expect(unconvert).not.toHaveBeenCalled()
  expect(queue.failedItems).toHaveLength(1)
})

// Recreate the persisted queue and stale DOM as they appear after a reload.
test.each([false, true])('restores a pending draft after reload (in flight: %s) before another edit', async processing => {
  const { unacknowledgedBody } = await import('../../lib/api/queue_recovery')
  queue.processing = processing
  queue.queue = JSON.parse(JSON.stringify([{
    dedupeKey: 'creative_42',
    body: {
      'creative[description]': '<p>offline draft</p>',
      'creative[content_type_input]': 'markdown',
      'creative[markdown_source]': 'offline draft',
      'creative[markdown_editor]': 'source',
      'creative[progress]': 1,
    },
  }]))
  queue.unacknowledgedBody.mockImplementation(key => unacknowledgedBody(queue, key))
  const { tree } = appendMarkdownRow('42', 'stale server')
  openRow(tree)
  const textarea = document.getElementById('markdown-editor-textarea')
  expect(textarea.value).toBe('offline draft')
  expect(document.getElementById('inline-creative-progress').checked).toBe(true)
  expect(tree.dataset.saveState).toBe('pending')
  textarea.value += ' continued'
  textarea.dispatchEvent(new Event('input'))
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(enqueue).toHaveBeenCalledTimes(1)
  const request = enqueue.mock.calls[0][0]
  expect(request.body['creative[markdown_source]']).toBe('offline draft continued')
  expect({ ...unacknowledgedBody(queue, request.dedupeKey), ...request.body }['creative[progress]']).toBe(1)
  request.onSuccess({})
  expect(tree.dataset.saveState).toBeUndefined()
})

test('closing a restored pending draft without edits queues it with completion tracking', async () => {
  queue.queue = [{ dedupeKey: 'creative_42' }]
  queue.unacknowledgedBody.mockReturnValue({
    'creative[description]': '<p>pending draft</p>',
    'creative[content_type_input]': 'markdown',
    'creative[markdown_source]': 'pending draft',
  })
  const { tree } = appendMarkdownRow('42', 'stale server')
  openRow(tree)
  document.getElementById('inline-close').click()
  await flushPromises()
  expect(enqueue).toHaveBeenCalledTimes(1)
  expect(enqueue.mock.calls[0][0].body['creative[markdown_source]']).toBe('pending draft')
  enqueue.mock.calls[0][0].onSuccess({})
  expect(tree.dataset.saveState).toBeUndefined()
})
