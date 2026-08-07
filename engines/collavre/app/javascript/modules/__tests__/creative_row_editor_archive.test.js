/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// Archiving is the one removal path with no server echo: Creative#archive! is an
// `update_all`, so it fires no destroy broadcast and the initiating window has to
// repair its own DOM — including bringing the empty-state placeholder back when
// the archived row was the last one.
const archive = jest.fn(() => Promise.resolve({ ok: true }))
const unarchive = jest.fn(() => Promise.resolve({ ok: true }))
const confirmDialog = jest.fn(() => Promise.resolve(true))

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: jest.fn(() => ({
    destroy: jest.fn(),
    load: jest.fn(),
    focus: jest.fn(),
    getDeletedAttachments: jest.fn(() => []),
  })),
}))
jest.unstable_mockModule('../creative_row_editor_delegated_clicks', () => ({
  createDelegatedClickHandler: jest.fn(() => jest.fn()),
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    archive,
    unarchive,
    get: jest.fn(() => Promise.resolve({})),
  },
}))
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  default: confirmDialog,
  confirmDialog,
  alertDialog: jest.fn(),
  promptDialog: jest.fn(),
}))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')
const { buildEditorDom } = await import('./support/inline_editor_dom')

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function rowMarkup(id) {
  return `
    <creative-tree-row creative-id="${id}">
      <div class="creative-tree" id="creative-${id}" data-id="${id}" data-level="1"></div>
    </creative-tree-row>
  `
}

// Post-client-render state: tree_controller wiped #creatives and rendered rows
// into it, so only the out-of-container template holds a pristine placeholder.
function renderTree(rowIds) {
  document.body.innerHTML = `
    <template id="creatives-empty-state-template">${EMPTY_HTML}</template>
    <div id="creatives">${rowIds.map(rowMarkup).join('')}</div>
    <div id="center-frame"></div>
  `
  const template = buildEditorDom(document.getElementById('center-frame'))
  initializeCreativeRowEditor()
  return template
}

async function archiveCreative(id) {
  document.getElementById('inline-edit-form-element').dataset.creativeId = String(id)
  document.getElementById('inline-archive').click()
  await flush()
  await flush()
}

function container() {
  return document.getElementById('creatives')
}

function placeholder() {
  return container().querySelector('[data-creatives-empty-state]')
}

afterEach(() => {
  jest.clearAllMocks()
  delete window.Stimulus
  document.body.innerHTML = ''
})

// Also a regression test for the `closeEditor()` ReferenceError that used to abort
// this handler: an unhandled rejection in the click promise fails the test.
test('archiving the last row brings the empty-state placeholder back', async () => {
  renderTree(['42'])

  await archiveCreative('42')

  expect(archive).toHaveBeenCalledWith('42')
  expect(container().querySelector('creative-tree-row')).toBeNull()
  expect(placeholder()).not.toBeNull()
  expect(placeholder().hidden).toBe(false)
  expect(placeholder().textContent).toContain('No sub-creatives found.')
})

test('archiving one of several rows leaves the placeholder off the page', async () => {
  renderTree(['42', '43'])

  await archiveCreative('42')

  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
})

test('restoring an archived row reloads the tree instead of removing it', async () => {
  renderTree(['42'])
  document.querySelector('creative-tree-row[creative-id="42"]').setAttribute('archived', '')
  const treeEl = container()
  treeEl.setAttribute('data-controller', 'creatives--tree')
  treeEl.dataset.loaded = 'true'
  const load = jest.fn()
  window.Stimulus = { getControllerForElementAndIdentifier: jest.fn(() => ({ load })) }

  await archiveCreative('42')

  expect(unarchive).toHaveBeenCalledWith('42')
  expect(archive).not.toHaveBeenCalled()
  expect(load).toHaveBeenCalledTimes(1)
  expect(treeEl.dataset.loaded).toBeUndefined()
  expect(treeEl.innerHTML).toBe('')
})

test('declining the archive confirmation leaves the row in place', async () => {
  confirmDialog.mockResolvedValueOnce(false)
  renderTree(['42'])

  await archiveCreative('42')

  expect(archive).not.toHaveBeenCalled()
  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
})
