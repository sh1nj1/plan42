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

// A workspace that loaded with rows has no placeholder left inside #creatives —
// the tree render wiped it. All that survives is the pristine copy in the
// server-rendered <template>, which restoreTreeEmptyState() clones. Set that up
// and then clear the container, so only the template is available.
//
// The label is deliberately not English: markup assembled inside the module
// rather than cloned from the server's template would fail this assertion.
function installTemplateOnly() {
  renderEmptyState()
  const template = document.getElementById('creatives-empty-state-template')
  template.innerHTML =
    '<div data-creatives-empty-state><div class="creative-empty-state">' +
    '<button type="button" class="new-root-creative-btn">추가</button></div></div>'
  document.getElementById('creatives').innerHTML = ''
}

// Stands in for the connected creatives--tree controller so the root-level refetch
// can be observed. Resolved through window.Stimulus on each call, as the archive
// handler does.
function stubTreeController() {
  const calls = { load: 0 }
  const controller = { load() { calls.load += 1 } }
  window.Stimulus = {
    getControllerForElementAndIdentifier: (element, identifier) => (
      element === document.getElementById('creatives') && identifier === 'creatives--tree' ? controller : null
    ),
  }
  return calls
}

// A child row nested under `parentId`, in the children container the delete path
// inspects.
function appendChildRow(parentId, childId) {
  let children = document.getElementById(`creative-children-${parentId}`)
  if (!children) {
    children = document.createElement('div')
    children.className = 'creative-children'
    children.id = `creative-children-${parentId}`
    document.getElementById(`creative-${parentId}`).appendChild(children)
  }
  return appendExistingRow(childId, children)
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
    delete window.Stimulus
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

  test('clones the server-rendered template when no card is left in the DOM', async () => {
    installTemplateOnly()
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    const restored = document.querySelector('#creatives .creative-empty-state')
    expect(restored).not.toBeNull()
    expect(restored.querySelector('.new-root-creative-btn').textContent).toBe('추가')
  })

  test('leaves the tree alone while other rows remain', async () => {
    installTemplateOnly()
    const { tree } = appendExistingRow(42)
    appendExistingRow(43)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    expect(document.querySelector('#creatives .creative-empty-state')).toBeNull()
  })

  test('does not re-render the empty state when the archive request fails', async () => {
    installTemplateOnly()
    archiveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-archive').click()
    await flush()

    // The row is still there, so there is nothing to replace it with.
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    expect(document.querySelector('#creatives .creative-empty-state')).toBeNull()
  })

  test('closes the editor when the deleted row was the last one', async () => {
    // move(1) has no row to move to here, so it used to leave currentTree on the
    // row being detached with the template still displayed. Hold the element:
    // removeTreeElement() takes the row away with the template inside it, so
    // getElementById would stop finding it either way.
    renderEmptyState()
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    const editor = document.getElementById('inline-edit-form')
    expect(editor.style.display).toBe('block')

    document.getElementById('inline-delete').click()
    await flush()

    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(0)
    expect(editor.style.display).toBe('none')
  })

  test('the restored Add button creates a row on the first click after a delete', async () => {
    // The symptom of leaving the editor open on the deleted row: the delegated
    // handler reads a displayed template as "close the open editor", so the first
    // click on the restored CTA did nothing but flush a save for a creative that
    // no longer exists.
    renderEmptyState()
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    document.querySelector('#creatives .new-root-creative-btn').click()
    await flush()

    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
  })

  test('refetches the root tree when "delete only this" promotes children to the root', async () => {
    // DestroyService#reparent_children moves the children up to the deleted
    // creative's parent — the root here, since this row is top level. The only
    // copy of them in the DOM is inside the children container the delete path
    // drops, so without a refetch the tree would show the "no creatives yet" card
    // while the server still holds the promoted rows.
    renderEmptyState()
    const calls = stubTreeController()
    const { tree } = appendExistingRow(42)
    appendChildRow(42, 43)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    expect(destroyMock).toHaveBeenCalledWith('42', false)
    expect(calls.load).toBe(1)
  })

  test('does not refetch when the deleted row has no children to promote', async () => {
    renderEmptyState()
    const calls = stubTreeController()
    const { tree } = appendExistingRow(42)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    expect(calls.load).toBe(0)
  })

  test('does not refetch when "delete with children" removes them too', async () => {
    // Nothing is promoted in this case: the children are gone from the server.
    renderEmptyState()
    const calls = stubTreeController()
    const { tree } = appendExistingRow(42)
    appendChildRow(42, 43)

    await openEditorOn(tree)
    document.getElementById('inline-delete-with-children').click()
    await flush()

    expect(destroyMock).toHaveBeenCalledWith('42', true)
    expect(calls.load).toBe(0)
  })

  test('keeps the editor open on the next row when one remains', async () => {
    renderEmptyState()
    const { tree } = appendExistingRow(42)
    appendExistingRow(43)

    await openEditorOn(tree)
    document.getElementById('inline-delete').click()
    await flush()

    // move(1) had somewhere to go, so the editor follows it rather than closing.
    expect(document.getElementById('inline-edit-form').style.display).toBe('block')
  })
})
