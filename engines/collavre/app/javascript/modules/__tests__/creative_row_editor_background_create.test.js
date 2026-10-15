/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// Enter on a new creative must open the next row right away: the previous
// row's POST runs in the background, and the next row's own create waits for
// that id so it is still positioned after it.
const createInlineEditorMock = jest.fn()
const saveMock = jest.fn()
const alertDialogMock = jest.fn(() => Promise.resolve())
let deletedAttachments = []

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: createInlineEditorMock,
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    save: saveMock,
    get: jest.fn(() => new Promise(() => {})),
    children: jest.fn(() => Promise.resolve([])),
  },
}))
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  alertDialog: alertDialogMock,
  confirmDialog: jest.fn(() => Promise.resolve(true)),
  promptDialog: jest.fn(() => Promise.resolve(null)),
}))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')
const { default: creativesApi } = await import('../../lib/api/creatives')
const {
  buildEditorDom, defineTreeRowStub, renderEmptyState, appendExistingRow, flush,
} = await import('./support/inline_editor_dom')

function deferred() {
  let resolve
  const promise = new Promise((r) => { resolve = r })
  return { promise, resolve }
}

function created(id) {
  return { ok: true, text: () => Promise.resolve(JSON.stringify({ id })) }
}

// The body the editor sent: a FormData for a background create, the form
// element itself for a regular save (read at call time, as fetch would).
function sentField(call, name) {
  const body = call[2]
  return (body instanceof FormData ? body : new FormData(body)).get(name)
}

const template = () => document.getElementById('inline-edit-form')

// The real <creative-tree-row> always renders a .creative-row, which startNew()
// hides while the editor covers it; the shared stub omits it, so add it here.
function editingTree() {
  const tree = template().parentElement
  if (!tree.querySelector('.creative-row')) {
    const row = document.createElement('div')
    row.className = 'creative-row'
    row.style.display = 'none'
    tree.insertBefore(row, tree.firstChild)
  }
  return tree
}

function type(text) {
  document.getElementById('inline-creative-description').value = text ? `<p>${text}</p>` : ''
  const textarea = document.getElementById('markdown-editor-textarea')
  textarea.value = text
  textarea.dispatchEvent(new Event('input'))
}

async function startNewRow(text) {
  renderEmptyState().querySelector('.new-root-creative-btn').click()
  await flush()
  const tree = editingTree()
  type(text)
  return tree
}

async function pressEnter() {
  document.getElementById('inline-add').click()
  await flush()
  return editingTree()
}

describe('Enter on a new creative saves it in the background', () => {
  beforeAll(() => {
    defineTreeRowStub()
    createInlineEditorMock.mockImplementation(() => ({
      destroy: jest.fn(),
      load: jest.fn(),
      focus: jest.fn(),
      reset: jest.fn(),
      getDeletedAttachments: jest.fn(() => deletedAttachments.splice(0)),
    }))
  })

  beforeEach(() => {
    document.body.innerHTML = '<div id="creatives"></div><div id="center-frame"></div>'
    saveMock.mockReset()
    alertDialogMock.mockClear()
    deletedAttachments = []
    global.fetch = jest.fn(() => Promise.resolve({ ok: true }))
    buildEditorDom(document.getElementById('center-frame'), { saveFailedMessage: 'Save failed' })
    initializeCreativeRowEditor()
    document.getElementById('metadata-popup').style.display = 'none'
  })

  test('Enter while a save waits for the previous id joins that save instead of creating the row twice', async () => {
    const firstPost = deferred()
    const sent = []
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementation((url, method, body) => {
        sent.push(new FormData(body))
        return Promise.resolve(created(78))
      })
    await startNewRow('first creative')
    const second = await pressEnter()
    type('second creative')
    const progress = document.getElementById('inline-creative-progress')
    progress.checked = true
    progress.dispatchEvent(new Event('change'))
    await flush()

    await pressEnter()
    expect(saveMock).toHaveBeenCalledTimes(1)

    firstPost.resolve(created(77))
    await flush()

    expect(sent).toHaveLength(1)
    expect(sent[0].get('creative[description]')).toBe('<p>second creative</p>')
    expect(sent[0].get('after_id')).toBe('77')
    expect(second.dataset.id).toBe('78')
    expect(template().parentElement).not.toBe(second)
  })

  test('opens the next row and shows the previous one while its POST is in flight', async () => {
    const pending = deferred()
    saveMock.mockImplementation(() => pending.promise)
    const first = await startNewRow('first creative')

    const next = await pressEnter()

    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][1]).toBe('POST')
    expect(sentField(saveMock.mock.calls[0], 'creative[description]')).toBe('<p>first creative</p>')
    expect(next).not.toBe(first)
    expect(template().style.display).toBe('block')
    expect(first.querySelector('.creative-row').style.display).toBe('')
    expect(first.parentElement.descriptionHtml).toContain('first creative')
    expect(first.dataset.saveState).toBe('pending')
    // The next row sits right after the one still being created.
    expect(first.parentElement.nextElementSibling).toBe(next.parentElement)

    pending.resolve(created(77))
    await flush()

    expect(first.dataset.id).toBe('77')
    expect(first.id).toBe('creative-77')
    expect(first.dataset.saveState).toBeUndefined()
    expect(first.parentElement.getAttribute('creative-id')).toBe('77')
    expect(next.dataset.id).toBeUndefined()
  })

  test('binds a created child row to its parent', async () => {
    saveMock.mockImplementation(() => Promise.resolve(created(77)))
    const first = await startNewRow('child creative')
    document.getElementById('inline-parent-id').value = '5'

    await pressEnter()
    await flush()

    const rowComponent = first.parentElement
    expect(first.dataset.parentId).toBe('5')
    expect(rowComponent.getAttribute('parent-id')).toBe('5')
    expect(rowComponent.isRoot).toBe(false)
  })

  test("the next row's create waits for the previous id and is placed after it", async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => Promise.resolve(created(78)))
    await startNewRow('first creative')
    await pressEnter()
    type('second creative')

    document.getElementById('inline-close').click()
    await flush()
    expect(saveMock).toHaveBeenCalledTimes(1)

    firstPost.resolve(created(77))
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(2)
    expect(sentField(saveMock.mock.calls[1], 'after_id')).toBe('77')
    expect(sentField(saveMock.mock.calls[1], 'creative[description]')).toBe('<p>second creative</p>')
  })

  test('chains repeated Enters so each create follows the one before it', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => Promise.resolve(created(78)))
    await startNewRow('first creative')
    const second = await pressEnter()
    type('second creative')
    const third = await pressEnter()

    expect(third).not.toBe(second)
    expect(saveMock).toHaveBeenCalledTimes(1)

    firstPost.resolve(created(77))
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(2)
    expect(sentField(saveMock.mock.calls[1], 'after_id')).toBe('77')
    expect(second.dataset.id).toBe('78')
  })

  test('a failed create keeps the text, says so, and the next row takes its slot', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(80)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-after-id').value = '5'

    await pressEnter()
    await flush()

    expect(alertDialogMock).toHaveBeenCalledWith('Save failed')
    expect(first.dataset.saveState).toBe('error')
    expect(first.querySelector('.creative-row').style.display).toBe('')
    expect(first.parentElement.descriptionHtml).toContain('first creative')

    type('second creative')
    document.getElementById('inline-close').click()
    await flush()

    expect(sentField(saveMock.mock.calls[1], 'after_id')).toBe('5')
  })

  test('a failed create without a localized message stays silent', async () => {
    document.getElementById('inline-edit-form-element').removeAttribute('data-save-failed-message')
    saveMock.mockImplementationOnce(() => Promise.reject(new Error('offline')))
    const first = await startNewRow('first creative')

    await pressEnter()
    await flush()

    expect(alertDialogMock).not.toHaveBeenCalled()
    expect(first.dataset.saveState).toBe('error')
  })

  test('moving up into a row still being created waits for its id first', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()

    document.getElementById('inline-move-up').click()
    await flush()
    expect(template().parentElement).not.toBe(first)

    firstPost.resolve(created(77))
    await flush()

    expect(template().parentElement).toBe(first)
  })

  test('moving up into a row whose create fails reopens its draft', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()

    document.getElementById('inline-move-up').click()
    firstPost.resolve({ ok: false, status: 422 })
    await flush()

    expect(template().parentElement).toBe(first)
    expect(document.getElementById('markdown-editor-textarea').value).toBe('first creative')
  })

  test('clicking a row whose create already failed reopens the draft and retries the create', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(81)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-after-id').value = '5'
    document.getElementById('inline-before-id').value = '6'
    const next = await pressEnter()
    await flush()
    expect(first.dataset.saveState).toBe('error')

    document.dispatchEvent(new CustomEvent('creative-edit-click', {
      detail: { treeElement: first }, cancelable: true,
    }))
    await flush()

    // The blank next row is dropped; the editor holds the rejected draft.
    expect(next.isConnected).toBe(false)
    expect(template().parentElement).toBe(first)
    expect(first.dataset.saveState).toBeUndefined()
    expect(document.getElementById('inline-edit-form-element').dataset.creativeId).toBe('')
    expect(document.getElementById('markdown-editor-textarea').value).toBe('first creative')

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(2)
    expect(saveMock.mock.calls[1][1]).toBe('POST')
    expect(sentField(saveMock.mock.calls[1], 'creative[description]')).toContain('first creative')
    expect(sentField(saveMock.mock.calls[1], 'after_id')).toBe('5')
    expect(sentField(saveMock.mock.calls[1], 'before_id')).toBe('6')
    expect(first.dataset.id).toBe('81')
  })

  function clickRow(tree) {
    document.dispatchEvent(new CustomEvent('creative-edit-click', {
      detail: { treeElement: tree }, cancelable: true,
    }))
  }

  async function retryFailedRow(tree) {
    clickRow(tree)
    await flush()
    document.getElementById('inline-close').click()
    await flush()
    return saveMock.mock.calls[saveMock.mock.calls.length - 1]
  }

  test('a failed before-positioned row retries in front of the row that took its slot', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(80)))
      .mockImplementationOnce(() => Promise.resolve(created(81)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    await pressEnter()
    await flush()
    type('second creative')
    document.getElementById('inline-close').click()
    await flush()
    expect(sentField(saveMock.mock.calls[1], 'before_id')).toBe('6')

    const retry = await retryFailedRow(first)

    expect(sentField(retry, 'creative[description]')).toContain('first creative')
    expect(sentField(retry, 'after_id')).toBe('')
    expect(sentField(retry, 'before_id')).toBe('80')
  })

  test('failed rows chained by Enter all retry in front of the next row created', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(82)))
      .mockImplementation(() => Promise.resolve(created(90)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    const second = await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    type('third creative')
    await flush()
    await pressEnter()
    await flush()
    expect(sentField(saveMock.mock.calls[2], 'before_id')).toBe('6')

    expect(sentField(await retryFailedRow(first), 'before_id')).toBe('82')
    expect(sentField(await retryFailedRow(second), 'before_id')).toBe('82')
  })

  test('chained failed rows retried out of order keep their on-screen order', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(83)))
      .mockImplementationOnce(() => Promise.resolve(created(91)))
      .mockImplementationOnce(() => Promise.resolve(created(92)))
      .mockImplementation(() => Promise.resolve(created(93)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    const second = await pressEnter()
    type('second creative')
    await flush()
    const third = await pressEnter()
    type('third creative')
    await flush()
    await pressEnter()
    type('fourth creative')
    await flush()
    await pressEnter()
    await flush()

    expect(sentField(await retryFailedRow(second), 'before_id')).toBe('83')
    expect(sentField(await retryFailedRow(third), 'before_id')).toBe('83')
    expect(sentField(await retryFailedRow(first), 'before_id')).toBe('91')
  })

  test('a failed row skips a successor that was removed before its retry', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(82)))
      .mockImplementationOnce(() => Promise.resolve(created(90)))
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    const second = await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    type('third creative')
    await flush()
    await pressEnter()
    await flush()

    await retryFailedRow(second)
    second.closest('creative-tree-row').remove()
    expect(sentField(await retryFailedRow(first), 'before_id')).toBe('82')
  })

  test('a failed row retries in front of a saved row added below it after its successor was removed', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(80)))
      .mockImplementationOnce(() => Promise.resolve(created(81)))
      .mockImplementation(() => Promise.resolve(created(82)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    const second = await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    type('third creative')
    document.getElementById('inline-close').click()
    await flush()
    expect(sentField(saveMock.mock.calls[2], 'after_id')).toBe('80')

    second.closest('creative-tree-row').remove()
    const retry = await retryFailedRow(first)

    expect(sentField(retry, 'after_id')).toBe('')
    expect(sentField(retry, 'before_id')).toBe('81')
  })

  test('a failed chain with no saved row below it retries in screen order', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(90)))
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-after-id').value = '5'
    const second = await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    await flush()

    expect(sentField(await retryFailedRow(first), 'after_id')).toBe('5')
    const retry = await retryFailedRow(second)
    expect(sentField(retry, 'after_id')).toBe('90')
    expect(sentField(retry, 'before_id')).toBe('')
  })

  test('a failed row whose Enter retry fails again still retries after the failed row above it', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(90)))
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-after-id').value = '5'
    const second = await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    await flush()

    clickRow(second)
    await flush()
    await pressEnter()
    await flush()
    expect(sentField(saveMock.mock.calls[2], 'creative[description]')).toContain('second creative')

    expect(sentField(await retryFailedRow(first), 'after_id')).toBe('5')
    const retry = await retryFailedRow(second)
    expect(sentField(retry, 'after_id')).toBe('90')
    expect(sentField(retry, 'before_id')).toBe('')
  })

  test('a failed row whose Enter retry fails again still retries in front of the row that took its slot', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(82)))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    await flush()

    clickRow(first)
    await flush()
    await pressEnter()
    await flush()
    expect(sentField(saveMock.mock.calls[2], 'before_id')).toBe('82')

    const retry = await retryFailedRow(first)
    expect(sentField(retry, 'creative[description]')).toContain('first creative')
    expect(sentField(retry, 'before_id')).toBe('82')
  })

  test('failed rows sharing a before anchor retried bottom-up keep their on-screen order', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(90)))
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-before-id').value = '6'
    const second = await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    await flush()

    expect(sentField(await retryFailedRow(second), 'before_id')).toBe('6')
    const retry = await retryFailedRow(first)
    expect(sentField(retry, 'creative[description]')).toContain('first creative')
    expect(sentField(retry, 'before_id')).toBe('90')
    expect(sentField(retry, 'after_id')).toBe('')
  })

  test('a failed row reopened while the row below it is still being created retries in front of it', async () => {
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => secondPost.promise)
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-after-id').value = '5'
    await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    await flush()

    clickRow(first)
    await flush()
    expect(template().parentElement).not.toBe(first)
    secondPost.resolve(created(85))
    await flush()
    expect(template().parentElement).toBe(first)
    document.getElementById('inline-close').click()
    await flush()

    const retry = saveMock.mock.calls.at(-1)
    expect(sentField(retry, 'creative[description]')).toContain('first creative')
    expect(sentField(retry, 'before_id')).toBe('85')
    expect(sentField(retry, 'after_id')).toBe('')
  })

  test('a failed row reopened while the row below it is being created keeps its slot when that create fails too', async () => {
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => secondPost.promise)
      .mockImplementation(() => Promise.resolve(created(91)))
    const first = await startNewRow('first creative')
    document.getElementById('inline-after-id').value = '5'
    await pressEnter()
    type('second creative')
    await flush()
    await pressEnter()
    await flush()

    clickRow(first)
    await flush()
    secondPost.resolve({ ok: false, status: 500 })
    await flush()
    expect(template().parentElement).toBe(first)
    document.getElementById('inline-close').click()
    await flush()

    expect(sentField(saveMock.mock.calls.at(-1), 'after_id')).toBe('5')
  })

  test('a completed failed draft keeps its completion when another row reset the baseline', async () => {
    const sentProgress = []
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementation((url, method, body) => {
        // Read the progress fields while the request is sent: a save that
        // skips progress disables them only until it settles.
        sentProgress.push(new FormData(body).getAll('creative[progress]'))
        return Promise.resolve(created(90))
      })
    const first = await startNewRow('done creative')
    document.getElementById('inline-creative-progress').checked = true
    await pressEnter()
    await flush()
    const { tree: completed, row } = appendExistingRow(7)
    row.closest('creative-tree-row').dataset.progressValue = '1'
    clickRow(completed)
    await flush()
    expect(document.getElementById('inline-creative-progress').checked).toBe(true)

    const retry = await retryFailedRow(first)

    expect(sentField(retry, 'creative[description]')).toContain('done creative')
    // A check box posts its hidden 0 first; the server keeps the last value.
    expect(sentProgress.at(-1).at(-1)).toBe('1')
  })

  test('a click that waits out a pending create yields to a later click', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()
    const other = document.createElement('div')
    other.className = 'creative-tree'
    document.getElementById('creatives').appendChild(other)

    clickRow(first)
    await flush()
    clickRow(other)
    await flush()
    expect(template().parentElement).toBe(other)

    firstPost.resolve(created(77))
    await flush()

    expect(template().parentElement).toBe(other)
  })

  test('a move that waits out a pending create yields to a later click', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    await startNewRow('first creative')
    await pressEnter()
    const other = document.createElement('div')
    other.className = 'creative-tree'
    document.getElementById('creatives').appendChild(other)

    document.getElementById('inline-move-up').click()
    await flush()
    clickRow(other)
    await flush()

    firstPost.resolve(created(77))
    await flush()

    expect(template().parentElement).toBe(other)
  })

  async function failThenReopen(prepare) {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(81)))
    const first = await startNewRow('')
    await prepare()
    await pressEnter()
    await flush()
    document.dispatchEvent(new CustomEvent('creative-edit-click', {
      detail: { treeElement: first }, cancelable: true,
    }))
    await flush()
    expect(template().parentElement).toBe(first)
    return first
  }

  const field = (id) => document.getElementById(id).value

  test('a failed Markdown-source draft reopens in the Markdown editor', async () => {
    await failThenReopen(async () => {
      document.getElementById('inline-toggle-markdown').click()
      await flush()
      type('# md draft')
    })

    expect(document.getElementById('markdown-editor-wrapper').style.display).toBe('')
    expect(field('markdown-editor-textarea')).toBe('# md draft')
    expect(field('inline-content-type')).toBe('markdown')
    expect(field('inline-markdown-editor')).toBe('source')

    document.getElementById('inline-close').click()
    await flush()
    expect(sentField(saveMock.mock.calls[1], 'creative[markdown_source]')).toBe('# md draft')
  })

  test('a failed rich-authored Markdown draft keeps its Markdown fields', async () => {
    await failThenReopen(() => {
      type('rich draft')
      document.getElementById('inline-content-type').value = 'markdown'
      document.getElementById('inline-markdown-source').value = 'rich draft'
      document.getElementById('inline-markdown-editor').value = 'rich'
    })

    expect(document.getElementById('markdown-editor-wrapper').style.display).toBe('none')
    expect(field('inline-creative-description')).toBe('<p>rich draft</p>')
    expect(field('inline-content-type')).toBe('markdown')
    expect(field('inline-markdown-source')).toBe('rich draft')
    expect(field('inline-markdown-editor')).toBe('rich')
  })

  test('a row with neither an id nor a failed draft loads nothing into the editor', async () => {
    document.getElementById('inline-after-id').value = 'stale'
    const stray = document.createElement('div')
    stray.className = 'creative-tree'
    document.getElementById('creatives').appendChild(stray)

    document.dispatchEvent(new CustomEvent('creative-edit-click', {
      detail: { treeElement: stray }, cancelable: true,
    }))
    await flush()

    expect(template().parentElement).toBe(stray)
    expect(field('inline-after-id')).toBe('stale')
  })

  const attachmentDeletes = () => global.fetch.mock.calls
    .filter(([, options]) => options?.method === 'DELETE').map(([url]) => url)

  test('attachments removed before a failed create are deleted once its retry succeeds', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(81)))
    const first = await startNewRow('first creative')
    deletedAttachments = ['blob-1']
    await pressEnter()
    await flush()
    expect(attachmentDeletes()).toEqual([])

    // A retry that fails again still holds on to them.
    clickRow(first)
    await flush()
    await pressEnter()
    await flush()
    expect(first.dataset.saveState).toBe('error')
    expect(attachmentDeletes()).toEqual([])

    await retryFailedRow(first)

    expect(first.dataset.id).toBe('81')
    expect(attachmentDeletes()).toEqual(['/attachments/blob-1'])
  })

  async function createMarkdownRow(finish) {
    saveMock.mockImplementation(() => Promise.resolve({
      ok: true,
      text: () => Promise.resolve(JSON.stringify({ id: 77, markdown_source: '![x](/blobs/1)' })),
    }))
    const first = await startNewRow('')
    document.getElementById('inline-toggle-markdown').click()
    await flush()
    type('![x](data:image/png;base64,AAAA)')
    await finish()
    await flush()
    return first
  }

  test('a background create caches the Markdown source the server rewrote', async () => {
    const first = await createMarkdownRow(pressEnter)

    expect(first.dataset.id).toBe('77')
    expect(first.parentElement.dataset.markdownSource).toBe('![x](/blobs/1)')
  })

  test('closing a new Markdown row caches the Markdown source the server rewrote', async () => {
    const first = await createMarkdownRow(() => document.getElementById('inline-close').click())

    expect(first.dataset.id).toBe('77')
    expect(first.parentElement.dataset.markdownSource).toBe('![x](/blobs/1)')
  })

  test('an upload in progress keeps the blocking save', async () => {
    saveMock.mockImplementation(() => Promise.resolve(created(77)))
    const first = await startNewRow('first creative')
    window.creativeRowEditor.setUploadsPending(true)

    document.getElementById('inline-add').click()
    await flush()

    expect(saveMock).not.toHaveBeenCalled()
    expect(first.dataset.saveState).toBeUndefined()

    window.creativeRowEditor.resolveUploadCompletion()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][2]).toBeInstanceOf(HTMLFormElement)
    expect(first.dataset.id).toBe('77')
  })

  test('a background create refreshes the created row and asks for the deferred reload', async () => {
    const refetch = jest.fn()
    document.addEventListener('creative-sync:refetch', refetch)
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    await startNewRow('first creative')
    await pressEnter()
    creativesApi.get.mockClear()

    firstPost.resolve(created(77))
    await flush()
    document.removeEventListener('creative-sync:refetch', refetch)

    expect(creativesApi.get).toHaveBeenCalledWith('77')
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  function frameRender(frame) {
    const event = new CustomEvent('turbo:before-frame-render', {
      bubbles: true, cancelable: true, detail: { resume: jest.fn() },
    })
    frame.dispatchEvent(event)
    return event
  }

  test('a frame swap waits for a background create in it to settle', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    await startNewRow('first creative')
    await pressEnter()

    const event = frameRender(document.getElementById('creatives'))
    expect(event.defaultPrevented).toBe(true)
    expect(frameRender(document.getElementById('center-frame')).defaultPrevented).toBe(false)
    await flush()
    expect(event.detail.resume).not.toHaveBeenCalled()

    firstPost.resolve(created(77))
    await flush()

    expect(event.detail.resume).toHaveBeenCalled()
  })

  test('a frame swap is dropped when the create it waited for fails, so the draft can be retried', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()

    const event = frameRender(document.getElementById('creatives'))
    firstPost.resolve({ ok: false, status: 500 })
    await flush()

    expect(event.detail.resume).not.toHaveBeenCalled()
    expect(first.isConnected).toBe(true)
    expect(first.dataset.saveState).toBe('error')
  })

  test('a frame swap with no background create in flight renders at once', async () => {
    await startNewRow('first creative')

    expect(frameRender(document.getElementById('creatives')).defaultPrevented).toBe(false)
  })
})
