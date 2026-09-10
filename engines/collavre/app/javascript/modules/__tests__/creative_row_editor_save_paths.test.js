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
