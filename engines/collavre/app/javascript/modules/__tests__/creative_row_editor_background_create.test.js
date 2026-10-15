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
const {
  buildEditorDom, defineTreeRowStub, renderEmptyState, flush,
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
      getDeletedAttachments: jest.fn(() => []),
    }))
  })

  beforeEach(() => {
    document.body.innerHTML = '<div id="creatives"></div><div id="center-frame"></div>'
    saveMock.mockReset()
    alertDialogMock.mockClear()
    buildEditorDom(document.getElementById('center-frame'), { saveFailedMessage: 'Save failed' })
    initializeCreativeRowEditor()
    document.getElementById('metadata-popup').style.display = 'none'
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
})
