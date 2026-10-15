/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// Closing the editor must show the row with the typed content right away; the
// save (a POST for a brand-new creative) finishes in the background.
const createInlineEditorMock = jest.fn()
const saveMock = jest.fn()

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
  alertDialog: jest.fn(() => Promise.resolve()),
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

describe('revealing the row as soon as the editor closes', () => {
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
    buildEditorDom(document.getElementById('center-frame'))
    initializeCreativeRowEditor()
    document.getElementById('metadata-popup').style.display = 'none'
  })

  // The real <creative-tree-row> always renders a .creative-row, which startNew()
  // hides while the editor covers it; the shared stub omits it, so add it here.
  async function startNewRow(text) {
    renderEmptyState().querySelector('.new-root-creative-btn').click()
    await flush()
    const rowComponent = document.querySelector('#creatives creative-tree-row')
    const tree = rowComponent.querySelector('.creative-tree')
    const row = document.createElement('div')
    row.className = 'creative-row'
    row.style.display = 'none'
    tree.insertBefore(row, tree.firstChild)

    document.getElementById('inline-creative-description').value = text ? `<p>${text}</p>` : ''
    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = text
    textarea.dispatchEvent(new Event('input'))
    return { rowComponent, tree, row }
  }

  test('shows the typed content while the create request is still in flight', async () => {
    const pending = deferred()
    saveMock.mockImplementation(() => pending.promise)
    const { rowComponent, row } = await startNewRow('first creative')

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(document.getElementById('inline-edit-form').style.display).toBe('none')
    expect(row.style.display).toBe('')
    expect(rowComponent.descriptionHtml).toContain('first creative')

    pending.resolve({ ok: true, text: () => Promise.resolve(JSON.stringify({ id: 77 })) })
    await flush()

    expect(row.style.display).toBe('')
    expect(rowComponent.descriptionHtml).toContain('first creative')
  })

  test('hides the row again and reopens the draft when the create fails', async () => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    const { tree, row } = await startNewRow('first creative')

    document.getElementById('inline-close').click()
    await flush()

    const template = document.getElementById('inline-edit-form')
    expect(row.style.display).toBe('none')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(tree)
  })

  test('leaves an empty new row hidden for removal', async () => {
    const { rowComponent, row } = await startNewRow('')
    document.getElementById('inline-creative-progress').checked = true
    document.getElementById('inline-creative-progress').dispatchEvent(new Event('change'))

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).not.toHaveBeenCalled()
    expect(row.style.display).toBe('none')
    expect(rowComponent.isConnected).toBe(false)
  })
})
