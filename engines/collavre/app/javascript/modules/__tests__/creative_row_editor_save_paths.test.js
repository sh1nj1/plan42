/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

let editorOptions = null
const save = jest.fn()
const enqueue = jest.fn()

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
    get: jest.fn(() => Promise.resolve({})),
    loadChildren: jest.fn(() => Promise.resolve({ creatives: [] })),
  },
}))
jest.unstable_mockModule('../../lib/api/queue_manager', () => ({
  default: {
    initialize: jest.fn(),
    start: jest.fn(),
    enqueue,
  },
}))

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
  enqueue.mockReset()
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

test('direct save keeps FormData semantics, applies a markdown rewrite, and clears dirty state', async () => {
  jest.useFakeTimers()
  const { tree } = appendMarkdownRow('42', 'before')
  openRow(tree)

  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = 'draft ![image](data:old)'
  textarea.dispatchEvent(new Event('input'))
  let submitted
  save.mockImplementation((_path, _method, form) => {
    submitted = new FormData(form)
    return response({
      markdown_source: 'draft ![image](/rails/active_storage/blobs/image.png)',
    })
  })

  const progress = document.getElementById('inline-creative-progress')
  progress.checked = true
  progress.dispatchEvent(new Event('change'))
  await flushPromises()

  expect(save).toHaveBeenCalledTimes(1)
  expect(save.mock.calls[0][0]).toMatch(/\/creatives\/42$/)
  expect(save.mock.calls[0][1]).toBe('PATCH')
  expect(submitted.get('creative[markdown_source]')).toBe('draft ![image](data:old)')
  expect(submitted.getAll('creative[progress]')).toEqual(['0', '1'])
  expect(textarea.value).toBe('draft ![image](/rails/active_storage/blobs/image.png)')
  expect(document.getElementById('inline-markdown-source').value)
    .toBe('draft ![image](/rails/active_storage/blobs/image.png)')

  document.getElementById('inline-close').click()
  await Promise.resolve()
  expect(save).toHaveBeenCalledTimes(1)
})

test('persistent queue snapshots the outgoing row, keeps its object body, applies response data, and clears dirty state', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before', 'rich')
  const second = appendMarkdownRow('43', 'second', 'rich')
  openRow(first.tree)

  editorOptions.onChange({ html: '<p>outgoing edit</p>', markdown: 'outgoing edit' })
  document.getElementById('inline-move-down').click()
  await Promise.resolve()
  await Promise.resolve()

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
  await Promise.resolve()
  await Promise.resolve()

  expect(enqueue).not.toHaveBeenCalled()
})

test('persistent queue carries an unacknowledged progress toggle into the body and row dataset', async () => {
  jest.useFakeTimers()
  const first = appendMarkdownRow('42', 'before', 'rich')
  appendMarkdownRow('43', 'second', 'rich')
  openRow(first.tree)

  // The checkbox fires a direct save; hold it in flight so the progress
  // baseline is still stale when the move queues the outgoing row.
  let settleDirectSave
  save.mockImplementation(() => new Promise((resolve) => { settleDirectSave = resolve }))
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

  settleDirectSave({ ok: true, text: () => Promise.resolve('{}') })
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
