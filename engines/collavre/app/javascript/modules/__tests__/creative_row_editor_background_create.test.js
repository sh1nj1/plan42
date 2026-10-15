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
const confirmDialogMock = jest.fn(() => Promise.resolve(true))
let deletedAttachments = []
let editorOptions = null
const linkPicker = { open: jest.fn() }
// The editor reads window.Stimulus when it is imported.
window.Stimulus = { getControllerForElementAndIdentifier: (_el, id) => (id === 'link-creative' ? linkPicker : null) }

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: createInlineEditorMock,
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    save: saveMock,
    get: jest.fn(() => new Promise(() => {})),
    children: jest.fn(() => Promise.resolve([])),
    destroy: jest.fn(() => new Promise(() => {})),
    archive: jest.fn(() => new Promise(() => {})),
    linkExisting: jest.fn(() => Promise.resolve()),
    updateMetadata: jest.fn(() => Promise.resolve({ ok: true })),
  },
}))
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  alertDialog: alertDialogMock,
  confirmDialog: confirmDialogMock,
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
    createInlineEditorMock.mockImplementation((container, options) => (editorOptions = options, {
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
    confirmDialogMock.mockReset().mockImplementation(() => Promise.resolve(true))
    deletedAttachments = []
    global.fetch = jest.fn(() => Promise.resolve({ ok: true }))
    buildEditorDom(document.getElementById('center-frame'), { saveFailedMessage: 'Save failed' })
    document.getElementById('inline-edit-form-element').dataset.discardFailedDraftMessage = 'Discard it?'
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

  test('a row moved up a level before its first save is placed where it now sits, not after the row above it', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => Promise.resolve(created(78)))
    const first = await startNewRow('nested creative')
    appendExistingRow(5)
    first.dataset.parentId = '5'
    document.getElementById('inline-parent-id').value = '5'
    await pressEnter()
    type('second creative')

    document.getElementById('inline-level-up').click()
    document.getElementById('inline-close').click()
    await flush()
    firstPost.resolve(created(77))
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(2)
    expect(sentField(saveMock.mock.calls[1], 'creative[parent_id]')).toBe('')
    expect(sentField(saveMock.mock.calls[1], 'after_id')).toBe('5')
    expect(sentField(saveMock.mock.calls[1], 'before_id')).toBe('')
  })

  test('a row moved up a level while its save waits for the row above is placed where it now sits', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementation(() => Promise.resolve(created(78)))
    const first = await startNewRow('nested creative')
    appendExistingRow(5)
    first.dataset.parentId = '5'
    document.getElementById('inline-parent-id').value = '5'
    await pressEnter()
    type('second creative')
    const progress = document.getElementById('inline-creative-progress')
    progress.checked = true
    progress.dispatchEvent(new Event('change'))
    await flush()

    document.getElementById('inline-level-up').click()
    firstPost.resolve(created(77))
    await flush()

    expect(sentField(saveMock.mock.calls[1], 'creative[parent_id]')).toBe('')
    expect(sentField(saveMock.mock.calls[1], 'after_id')).toBe('5')
    expect(sentField(saveMock.mock.calls[1], 'before_id')).toBe('')
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

  test('a failed parent draft retries with the child it was to adopt', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(81)))
    const first = await startNewRow('parent creative')
    document.getElementById('inline-child-id').value = '42'
    await pressEnter()
    await flush()
    expect(sentField(saveMock.mock.calls[0], 'child_id')).toBe('42')

    document.dispatchEvent(new CustomEvent('creative-edit-click', {
      detail: { treeElement: first }, cancelable: true,
    }))
    await flush()
    expect(document.getElementById('inline-child-id').value).toBe('42')
    document.getElementById('inline-close').click()
    await flush()

    expect(sentField(saveMock.mock.calls[1], 'child_id')).toBe('42')
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

  test('a failed row retries after the saved row now above it, not one moved away since', async () => {
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

    const otherParent = document.createElement('div')
    document.body.appendChild(otherParent)
    otherParent.appendChild(first.closest('creative-tree-row'))
    const retry = await retryFailedRow(second)

    expect(sentField(retry, 'after_id')).toBe('5')
    expect(sentField(retry, 'before_id')).toBe('')
  })

  test('a failed row retries after a saved row moved in above it', async () => {
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
    await retryFailedRow(first)

    const secondRow = second.closest('creative-tree-row')
    const { rowComponent } = appendExistingRow(70, secondRow.parentElement)
    secondRow.before(rowComponent)
    const retry = await retryFailedRow(second)

    expect(sentField(retry, 'after_id')).toBe('70')
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

  test('a failed row above a retry that fails again waits for the row opened after that retry', async () => {
    const thirdPost = deferred()
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => thirdPost.promise)
      .mockImplementation(() => Promise.resolve(created(92)))
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
    type('third creative')
    await pressEnter()
    await flush()
    expect(sentField(saveMock.mock.calls[3], 'creative[description]')).toContain('third creative')

    clickRow(first)
    await flush()
    expect(saveMock).toHaveBeenCalledTimes(4)

    thirdPost.resolve(created(91))
    await flush()
    const retry = await retryFailedRow(first)
    expect(sentField(retry, 'creative[description]')).toContain('first creative')
    expect(sentField(retry, 'before_id')).toBe('91')
    expect(sentField(retry, 'after_id')).toBe('')
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

  test('a failed draft reopened after a completed row with children can change its progress', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
    const first = await startNewRow('first creative')
    await pressEnter()
    await flush()
    const { tree: parent, rowComponent } = appendExistingRow(7)
    rowComponent.dataset.progressValue = '1'
    rowComponent.setAttribute('has-children', 'true')
    clickRow(parent)
    await flush()
    const progress = document.getElementById('inline-creative-progress')
    expect(progress.disabled).toBe(true)

    clickRow(first)
    await flush()

    expect(template().parentElement).toBe(first)
    expect(progress.disabled).toBe(false)
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

  test.each([
    ['Enter', () => document.getElementById('inline-add').click(), (opened, existing) => opened.parentElement.previousElementSibling?.querySelector('.creative-tree') === existing],
    ['Alt+Enter', () => editorOptions.onKeyDown({ key: 'Enter', altKey: true, preventDefault: jest.fn() }, {}), (opened, existing) => existing.contains(opened)],
  ])('a click that waits out a pending create yields to a later %s whose save is still waiting', async (_key, add, placedFromExisting) => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementation(() => Promise.resolve({ ok: true, text: () => Promise.resolve('{}') }))
    const first = await startNewRow('first creative')
    await pressEnter()
    const { tree: existing } = appendExistingRow(5)
    clickRow(existing)
    await flush()
    type('edited existing')
    window.creativeRowEditor.setUploadsPending(true)

    clickRow(first)
    await flush()
    add()
    await flush()

    firstPost.resolve(created(77))
    await flush()
    expect(template().parentElement).toBe(existing)

    window.creativeRowEditor.resolveUploadCompletion()
    await flush()

    const opened = editingTree()
    expect(opened).not.toBe(first)
    expect(opened).not.toBe(existing)
    expect(placedFromExisting(opened, existing)).toBe(true)
    expect(first.querySelector('.creative-row').style.display).not.toBe('none')
  })

  test.each([
    ['the close button', () => document.getElementById('inline-close').click()],
    ['Escape', () => editorOptions.onKeyDown({ key: 'Escape', preventDefault: jest.fn() }, {})],
    ['Escape in the markdown source', () => document.getElementById('markdown-editor-textarea').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))],
    ['the outer add button', () => document.querySelector('.new-root-creative-btn').click()],
  ])('a click that waits out a pending create yields to closing the editor with %s', async (_name, close) => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()
    const form = template()

    clickRow(first)
    await flush()
    close()
    await flush()
    firstPost.resolve(created(77))
    await flush()

    expect(first.contains(form)).toBe(false)
    expect(first.querySelector('.creative-row').style.display).not.toBe('none')
  })

  test.each([
    ['Delete', 'inline-delete', 'destroy', ['9', false]],
    ['Delete with children', 'inline-delete-with-children', 'destroy', ['9', true]],
    ['Archive', 'inline-archive', 'archive', ['9']],
  ])('a click that waits out a pending create yields to %s confirmed on the open row', async (_name, buttonId, call, args) => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementation(() => Promise.resolve({ ok: true, text: () => Promise.resolve('{}') }))
    creativesApi[call].mockClear()
    const first = await startNewRow('first creative')
    await pressEnter()
    const { tree: existing } = appendExistingRow(9)
    clickRow(existing)
    await flush()
    const confirmation = deferred()
    confirmDialogMock.mockImplementationOnce(() => confirmation.promise)

    clickRow(first)
    await flush()
    document.getElementById(buttonId).click()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    expect(template().parentElement).toBe(existing)
    confirmation.resolve(true)
    await flush()

    expect(creativesApi[call]).toHaveBeenCalledTimes(1)
    expect(creativesApi[call]).toHaveBeenCalledWith(...args)
    expect(first.querySelector('.creative-row').style.display).not.toBe('none')
  })

  test.each([
    ['to Markdown', 'confirmToMarkdown', () => {
      document.getElementById('inline-creative-description').value = '<p>existing creative</p>'
    }],
    ['back to rich text', 'confirmToRichtext', () => document.getElementById('inline-toggle-markdown').click()],
  ])('a click that waits out a pending create yields to the markdown toggle %s confirmed on the open row', async (_name, confirmKey, prepare) => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()
    const { tree: existing } = appendExistingRow(9)
    clickRow(existing)
    await flush()
    prepare()
    await flush()
    const toggle = document.getElementById('inline-toggle-markdown')
    toggle.dataset[confirmKey] = 'Switch?'
    const confirmation = deferred()
    confirmDialogMock.mockImplementationOnce(() => confirmation.promise)

    clickRow(first)
    await flush()
    toggle.click()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    expect(template().parentElement).toBe(existing)
    confirmation.resolve(true)
    await flush()

    expect(confirmDialogMock.mock.calls.at(-1)[0]).toBe('Switch?')
    expect(template().parentElement).toBe(existing)
    expect(first.querySelector('.creative-row').style.display).not.toBe('none')
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

  test('a frame swap also waits for a create started while it was paused', async () => {
    const firstPost = deferred()
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise).mockImplementationOnce(() => secondPost.promise)
    await startNewRow('first creative')
    await pressEnter()
    const event = frameRender(document.getElementById('creatives'))

    type('second creative')
    await pressEnter()
    firstPost.resolve(created(77))
    await flush()
    expect(event.detail.resume).not.toHaveBeenCalled()

    secondPost.resolve(created(78))
    await flush()
    expect(event.detail.resume).toHaveBeenCalled()
  })

  test('a frame swap is dropped when a create started while it was paused fails', async () => {
    const firstPost = deferred()
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise).mockImplementationOnce(() => secondPost.promise)
    await startNewRow('first creative')
    const second = await pressEnter()
    const event = frameRender(document.getElementById('creatives'))

    type('second creative')
    await pressEnter()
    firstPost.resolve(created(77))
    await flush()
    secondPost.resolve({ ok: false, status: 500 })
    await flush()

    expect(event.detail.resume).not.toHaveBeenCalled()
    expect(second.isConnected).toBe(true)
    expect(second.dataset.saveState).toBe('error')
  })

  function toggleProgress() {
    const progress = document.getElementById('inline-creative-progress')
    progress.checked = !progress.checked
    progress.dispatchEvent(new Event('change'))
  }

  test('a frame swap also waits for a save of the open new row started while it was paused', async () => {
    const firstPost = deferred()
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise).mockImplementationOnce(() => secondPost.promise)
    await startNewRow('first creative')
    await pressEnter()
    const event = frameRender(document.getElementById('creatives'))

    type('second creative')
    toggleProgress()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    expect(saveMock).toHaveBeenCalledTimes(2)
    expect(event.detail.resume).not.toHaveBeenCalled()

    secondPost.resolve(created(78))
    await flush()
    expect(event.detail.resume).toHaveBeenCalled()
  })

  test('a frame swap is dropped when a save of the open new row started while it was paused fails', async () => {
    const firstPost = deferred()
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise).mockImplementationOnce(() => secondPost.promise)
    await startNewRow('first creative')
    const second = await pressEnter()
    const event = frameRender(document.getElementById('creatives'))

    type('second creative')
    toggleProgress()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    secondPost.resolve({ ok: false, status: 500, clone: () => ({ json: () => Promise.resolve({}) }) })
    await flush()

    expect(event.detail.resume).not.toHaveBeenCalled()
    expect(second.isConnected).toBe(true)
    expect(template().parentElement).toBe(second)
  })

  test.each([
    ['is dropped when the user keeps it', false, false],
    ['renders once the save goes through', true, true],
  ])('a later frame swap over an open new row whose save failed during an earlier one %s', async (_name, retryOk, resumes) => {
    const firstPost = deferred()
    const secondPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise).mockImplementationOnce(() => secondPost.promise)
      .mockImplementation(() => Promise.resolve(retryOk ? created(79) : { ok: false, status: 500, clone: () => ({ json: () => Promise.resolve({}) }) }))
    confirmDialogMock.mockImplementationOnce(() => Promise.resolve(false))
    await startNewRow('first creative')
    const second = await pressEnter()
    frameRender(document.getElementById('creatives'))
    type('second creative')
    toggleProgress()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    secondPost.resolve({ ok: false, status: 500, clone: () => ({ json: () => Promise.resolve({}) }) })
    await flush()

    const event = frameRender(document.getElementById('creatives'))
    expect(event.defaultPrevented).toBe(true)
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(3)
    expect(confirmDialogMock).toHaveBeenCalledTimes(resumes ? 0 : 1)
    expect(event.detail.resume).toHaveBeenCalledTimes(resumes ? 1 : 0)
    expect(second.isConnected).toBe(true)
  })

  test('a frame swap is not held by a save of the open row that has nothing to create', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    await startNewRow('first creative')
    await pressEnter()
    const event = frameRender(document.getElementById('creatives'))

    toggleProgress()
    toggleProgress()
    await flush()
    firstPost.resolve(created(77))
    await flush()

    expect(event.detail.resume).toHaveBeenCalled()
  })

  test.each([
    ['saves an edit made while the open new row was being created before it renders', created(78), true],
    ['asks before discarding an edit made while the open new row was being created that could not be saved', { ok: false, status: 500, clone: () => ({ json: () => Promise.resolve({}) }) }, false],
  ])('a frame swap %s', async (_name, patchResult, resumes) => {
    confirmDialogMock.mockImplementationOnce(() => Promise.resolve(false))
    const firstPost = deferred()
    const secondPost = deferred()
    const patch = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => secondPost.promise)
      .mockImplementationOnce(() => patch.promise)
    await startNewRow('first creative')
    const second = await pressEnter()
    const event = frameRender(document.getElementById('creatives'))

    type('second creative')
    toggleProgress()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    type('second creative, edited')
    secondPost.resolve(created(78))
    await flush()
    expect(event.detail.resume).not.toHaveBeenCalled()
    expect(saveMock).toHaveBeenCalledTimes(3)
    expect(saveMock.mock.calls[2][1]).toBe('PATCH')
    expect(sentField(saveMock.mock.calls[2], 'creative[description]')).toContain('second creative, edited')

    patch.resolve(patchResult)
    await flush()
    expect(event.detail.resume).toHaveBeenCalledTimes(resumes ? 1 : 0)
    expect(confirmDialogMock).toHaveBeenCalledTimes(resumes ? 0 : 1)
    expect(second.isConnected).toBe(true)
  })

  test('a frame swap stays dropped when the failed row it waited for is reopened before it settles', async () => {
    const firstPost = deferred()
    const secondPost = deferred()
    const thirdPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => secondPost.promise)
      .mockImplementationOnce(() => thirdPost.promise)
    const first = await startNewRow('first creative')
    await pressEnter()
    type('second creative')
    await pressEnter()
    type('third creative')
    await pressEnter()
    const event = frameRender(document.getElementById('creatives'))
    firstPost.resolve({ ok: false, status: 500 })
    await flush()
    secondPost.resolve(created(78))
    await flush()

    clickRow(first)
    await flush()
    expect(template().parentElement).toBe(first)
    thirdPost.resolve(created(79))
    await flush()

    expect(event.detail.resume).not.toHaveBeenCalled()
    expect(first.isConnected).toBe(true)
  })

  test('a frame swap resumes once a failed row it waited for is retried successfully', async () => {
    const firstPost = deferred()
    const thirdPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => Promise.resolve(created(78)))
      .mockImplementationOnce(() => thirdPost.promise)
      .mockImplementation(() => Promise.resolve(created(80)))
    const first = await startNewRow('first creative')
    await pressEnter()
    type('second creative')
    await pressEnter()
    type('third creative')
    await pressEnter()
    const event = frameRender(document.getElementById('creatives'))
    firstPost.resolve({ ok: false, status: 500 })
    await flush()

    clickRow(first)
    await flush()
    await pressEnter()
    await flush()
    expect(first.dataset.id).toBe('80')
    thirdPost.resolve(created(79))
    await flush()

    expect(event.detail.resume).toHaveBeenCalled()
  })

  test('a frame swap over a row whose create already failed renders once the user discards it', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
    await startNewRow('first creative')
    await pressEnter()
    await flush()

    const event = frameRender(document.getElementById('creatives'))
    expect(event.defaultPrevented).toBe(true)
    await flush()

    expect(confirmDialogMock).toHaveBeenCalledWith('Discard it?', { danger: true })
    expect(event.detail.resume).toHaveBeenCalled()
  })

  test.each([
    ['deleted when the user discards it', true, ['/attachments/blob-1']],
    ['kept for a retry when the user keeps it', false, []],
  ])('attachments removed before a failed create are %s on a frame swap', async (_case, agreed, deletes) => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
    confirmDialogMock.mockImplementationOnce(() => Promise.resolve(agreed))
    await startNewRow('first creative')
    deletedAttachments = ['blob-1']
    await pressEnter()
    await flush()

    const event = frameRender(document.getElementById('creatives'))
    await flush()

    expect(event.detail.resume).toHaveBeenCalledTimes(agreed ? 1 : 0)
    expect(attachmentDeletes()).toEqual(deletes)
  })

  test('attachments removed before a reopened failed draft are deleted when the user discards it after it fails again', async () => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    const first = await startNewRow('first creative')
    deletedAttachments = ['blob-1']
    await pressEnter()
    await flush()
    clickRow(first)
    await flush()

    const event = frameRender(document.getElementById('creatives'))
    await flush()

    expect(event.detail.resume).toHaveBeenCalledTimes(1)
    expect(attachmentDeletes()).toEqual(['/attachments/blob-1'])
  })

  test('a frame swap over a reopened failed draft that cannot be saved again is dropped when the user keeps it', async () => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    confirmDialogMock.mockImplementationOnce(() => Promise.resolve(false))
    const first = await startNewRow('first creative')
    await pressEnter()
    await flush()
    clickRow(first)
    await flush()

    const event = frameRender(document.getElementById('creatives'))
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(2)
    expect(confirmDialogMock).toHaveBeenCalledTimes(1)
    expect(event.detail.resume).not.toHaveBeenCalled()
    expect(template().parentElement).toBe(first)
  })

  test('a frame swap over a reopened failed draft saves it and renders once it is created', async () => {
    saveMock.mockImplementationOnce(() => Promise.resolve({ ok: false, status: 500 }))
      .mockImplementationOnce(() => Promise.resolve(created(80)))
    const first = await startNewRow('first creative')
    await pressEnter()
    await flush()
    clickRow(first)
    await flush()

    const event = frameRender(document.getElementById('creatives'))
    await flush()

    expect(first.dataset.id).toBe('80')
    expect(confirmDialogMock).not.toHaveBeenCalled()
    expect(event.detail.resume).toHaveBeenCalledTimes(1)
  })

  test('a frame swap after a create succeeded renders at once', async () => {
    saveMock.mockImplementation(() => Promise.resolve(created(77)))
    await startNewRow('first creative')
    await pressEnter()
    await flush()

    expect(frameRender(document.getElementById('creatives')).defaultPrevented).toBe(false)
    expect(confirmDialogMock).not.toHaveBeenCalled()
  })

  test('a frame swap with no background create in flight renders at once', async () => {
    await startNewRow('first creative')

    expect(frameRender(document.getElementById('creatives')).defaultPrevented).toBe(false)
  })

  test('a click that waits out a pending create yields to opening the link picker on the open row', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    creativesApi.linkExisting.mockClear()
    linkPicker.open.mockClear()
    const first = await startNewRow('first creative')
    await pressEnter()
    const { tree: existing } = appendExistingRow(9)
    clickRow(existing)
    await flush()

    clickRow(first)
    await flush()
    document.getElementById('inline-link').click()
    await flush()
    firstPost.resolve(created(77))
    await flush()
    expect(template().parentElement).toBe(existing)
    linkPicker.open.mock.calls[0][1]({ id: 42 })
    await flush()

    expect(creativesApi.linkExisting).toHaveBeenCalledWith('9', 42)
  })

  test('a click that waits out a pending create yields to opening the inline link picker on the open row', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    linkPicker.open.mockClear()
    const modal = document.createElement('div')
    modal.id = 'link-creative-modal'
    document.body.appendChild(modal)
    const first = await startNewRow('first creative')
    await pressEnter()
    const { tree: existing } = appendExistingRow(9)
    clickRow(existing)
    await flush()

    clickRow(first)
    await flush()
    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'see\n/creative'
    textarea.setSelectionRange(textarea.value.length, textarea.value.length)
    textarea.dispatchEvent(new Event('input'))
    await flush()
    firstPost.resolve(created(77))
    await flush()
    modal.remove()

    expect(linkPicker.open).toHaveBeenCalledTimes(1)
    expect(template().parentElement).toBe(existing)
    linkPicker.open.mock.calls[0][1]({ id: 42, label: 'Target' })
    expect(textarea.value).toBe('see\n[Target](/creatives/42) ')
  })

  test('a link picked after the editor moved on still goes to the row the picker was opened on', async () => {
    creativesApi.linkExisting.mockClear()
    linkPicker.open.mockClear()
    const { tree: existing } = appendExistingRow(9)
    const { tree: other } = appendExistingRow(10)
    clickRow(existing)
    await flush()
    document.getElementById('inline-link').click()
    clickRow(other)
    await flush()
    expect(template().parentElement).toBe(other)

    linkPicker.open.mock.calls[0][1]({ id: 42 })
    await flush()

    expect(creativesApi.linkExisting).toHaveBeenCalledWith('9', 42)
  })

  test('a slow refresh after a background create does not overwrite an edit made since', async () => {
    const refresh = deferred()
    saveMock.mockImplementation(() => Promise.resolve(created(77)))
    creativesApi.get.mockImplementationOnce(() => refresh.promise)
    const first = await startNewRow('first creative')
    await pressEnter()
    await flush()
    expect(first.dataset.id).toBe('77')

    clickRow(first)
    await flush()
    type('edited creative')
    document.getElementById('inline-close').click()
    await flush()
    const row = first.parentElement
    expect(row.dataset.descriptionRawHtml).toBe('<p>edited creative</p>')

    refresh.resolve({ id: 77, description: '<p>first creative</p>' })
    await flush()

    expect(row.dataset.descriptionRawHtml).toBe('<p>edited creative</p>')
  })

  test('a row refresh applies its response when nothing changed the row since', async () => {
    const refresh = deferred()
    saveMock.mockImplementation(() => Promise.resolve(created(77)))
    creativesApi.get.mockImplementationOnce(() => refresh.promise)
    const first = await startNewRow('first creative')
    await pressEnter()
    await flush()

    refresh.resolve({ id: 77, description: '<p>from server</p>' })
    await flush()

    expect(first.parentElement.dataset.descriptionRawHtml).toBe('<p>from server</p>')
  })

  test.each([
    ['deleted when the user discards it', true, ['/attachments/blob-2', '/attachments/blob-1']],
    ['kept when the user keeps it', false, []],
  ])('attachments removed after reopening a failed draft that fails again are %s', async (_case, agreed, deletes) => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    confirmDialogMock.mockImplementationOnce(() => Promise.resolve(agreed))
    const first = await startNewRow('first creative')
    deletedAttachments = ['blob-1']
    await pressEnter()
    await flush()
    clickRow(first)
    await flush()
    deletedAttachments = ['blob-2']

    const event = frameRender(document.getElementById('creatives'))
    await flush()

    expect(event.detail.resume).toHaveBeenCalledTimes(agreed ? 1 : 0)
    expect(attachmentDeletes()).toEqual(deletes)
  })

  test('attachments removed from a saved row whose edit cannot be saved stay when it is discarded', async () => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    // A failed new row elsewhere holds the render and has it ask to discard.
    await startNewRow('first creative')
    await pressEnter()
    await flush()
    const { tree: existing } = appendExistingRow(9)
    clickRow(existing)
    await flush()
    type('edited creative')
    deletedAttachments = ['blob-3']

    const event = frameRender(document.getElementById('creatives'))
    await flush()

    expect(event.detail.resume).toHaveBeenCalledTimes(1)
    expect(attachmentDeletes()).toEqual([])
  })

  test('a row reparented while its create waits for the previous id is bound to its new parent', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
      .mockImplementationOnce(() => Promise.resolve(created(78)))
    await startNewRow('first creative')
    const second = await pressEnter()
    type('second creative')
    document.getElementById('inline-close').click()
    await flush()
    document.getElementById('inline-parent-id').value = '5'

    firstPost.resolve(created(77))
    await flush()

    expect(sentField(saveMock.mock.calls[1], 'creative[parent_id]')).toBe('5')
    expect(second.dataset.id).toBe('78')
    expect(second.dataset.parentId).toBe('5')
    expect(second.parentElement.getAttribute('parent-id')).toBe('5')
  })

  test('attachments removed from a failed draft are deleted when it is emptied and closed', async () => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    const first = await startNewRow('first creative')
    deletedAttachments = ['blob-1']
    await pressEnter()
    await flush()
    clickRow(first)
    await flush()
    deletedAttachments = ['blob-2']
    type('')

    document.getElementById('inline-close').click()
    await flush()

    expect(first.isConnected).toBe(false)
    expect(attachmentDeletes()).toEqual(['/attachments/blob-1', '/attachments/blob-2'])
  })

  test('a click that waits out a pending create yields to opening the metadata editor on the open row', async () => {
    const firstPost = deferred()
    saveMock.mockImplementationOnce(() => firstPost.promise)
    creativesApi.updateMetadata.mockClear()
    const first = await startNewRow('first creative')
    await pressEnter()
    const { tree: existing } = appendExistingRow(9)
    clickRow(existing)
    await flush()

    clickRow(first)
    await flush()
    document.getElementById('inline-metadata-btn').click()
    firstPost.resolve(created(77))
    await flush()
    expect(template().parentElement).toBe(existing)
    document.getElementById('metadata-save-btn').click()
    await flush()

    expect(creativesApi.updateMetadata).toHaveBeenCalledWith('9', {})
  })

  test('the metadata editor kept open across a switch saves to the row opened since', async () => {
    creativesApi.updateMetadata.mockClear()
    const { tree: existing } = appendExistingRow(9)
    const { tree: other } = appendExistingRow(10)
    clickRow(existing)
    await flush()
    document.getElementById('inline-metadata-btn').click()
    clickRow(other)
    await flush()
    document.getElementById('metadata-save-btn').click()
    await flush()

    expect(creativesApi.updateMetadata).toHaveBeenCalledWith('10', {})
  })
})
