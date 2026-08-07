/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// The real inline editor is a JSX module (untransformed in Jest), so it is
// stubbed. Everything else — the delete/archive button handlers, the empty
// state bookkeeping — is the real module.
const createInlineEditorMock = jest.fn()
const destroyMock = jest.fn()
const archiveMock = jest.fn()
const unarchiveMock = jest.fn()

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: createInlineEditorMock,
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    save: jest.fn(() => Promise.resolve({ ok: true })),
    get: jest.fn(() => Promise.resolve({})),
    children: jest.fn(() => Promise.resolve([])),
    destroy: destroyMock,
    archive: archiveMock,
    unarchive: unarchiveMock,
  },
}))
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  alertDialog: jest.fn(() => Promise.resolve()),
  confirmDialog: jest.fn(() => Promise.resolve(true)),
  promptDialog: jest.fn(() => Promise.resolve(null)),
}))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')
const {
  buildEditorDom, defineTreeRowStub, renderEmptyState, appendExistingRow, flush,
} = await import('./support/inline_editor_dom')

// Stands in for the `data-creatives--tree-empty-html-value` the ERB puts on
// #creatives: the same markup the tree controller re-renders for a
// server-confirmed-empty response.
const EMPTY_HTML = '<div class="creative-empty-state"><button type="button" class="new-root-creative-btn">추가</button></div>'

function setEmptyHtmlValue(html = EMPTY_HTML) {
  document.getElementById('creatives').setAttribute('data-creatives--tree-empty-html-value', html)
}

async function openEditorOn(tree) {
  document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
  await flush()
}

describe('empty state after the last creative is removed', () => {
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
    destroyMock.mockReset()
    destroyMock.mockImplementation(() => Promise.resolve({ ok: true }))
    archiveMock.mockReset()
    archiveMock.mockImplementation(() => Promise.resolve({ ok: true }))
    unarchiveMock.mockReset()
    unarchiveMock.mockImplementation(() => Promise.resolve({ ok: true }))
    buildEditorDom(document.getElementById('center-frame'))
    initializeCreativeRowEditor()
    document.getElementById('metadata-popup').style.display = 'none'
  })

  test('restores the hidden card when the first creative is deleted again', async () => {
    // The card is still in #creatives, hidden by the inline-create flow that
    // produced this creative in the first place.
    const emptyState = renderEmptyState()
    emptyState.style.display = 'none'
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    expect(destroyMock).toHaveBeenCalledWith('42', false)
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(0)
    expect(emptyState.style.display).toBe('')
  })

  test('restores the hidden card when the last creative is archived', async () => {
    const emptyState = renderEmptyState()
    emptyState.style.display = 'none'
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-archive').click()
    await flush()

    expect(archiveMock).toHaveBeenCalledWith('42')
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(0)
    expect(emptyState.style.display).toBe('')
  })

  test('renders the empty state from the tree markup when no card is in the DOM', async () => {
    // A workspace that loaded with rows never had the card rendered — the tree
    // controller replaced the server-rendered empty HTML with the real tree.
    setEmptyHtmlValue()
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    const restored = document.querySelector('#creatives .creative-empty-state')
    expect(restored).not.toBeNull()
    expect(restored.style.display).toBe('')
    expect(restored.querySelector('.new-root-creative-btn').textContent).toBe('추가')
  })

  test('leaves the tree alone while other rows remain', async () => {
    setEmptyHtmlValue()
    const { tree } = appendExistingRow(42)
    appendExistingRow(43)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    expect(document.querySelector('#creatives .creative-empty-state')).toBeNull()
  })

  test('does not re-render the empty state when the archive request fails', async () => {
    setEmptyHtmlValue()
    archiveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-archive').click()
    await flush()

    // The row is still there, so there is nothing to replace it with.
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    expect(document.querySelector('#creatives .creative-empty-state')).toBeNull()
  })
})
