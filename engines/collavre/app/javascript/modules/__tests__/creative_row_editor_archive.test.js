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
const save = jest.fn(() => Promise.resolve({ ok: true, text: () => Promise.resolve('{}') }))
const confirmDialog = jest.fn(() => Promise.resolve(true))
const alertDialog = jest.fn()

// Captured so a test can drive the editor's onChange callback directly and leave
// the session with a pending save, the way typing into Lexical would.
let editorOptions = null

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: jest.fn((_container, options) => {
    editorOptions = options
    return {
      destroy: jest.fn(),
      load: jest.fn(),
      focus: jest.fn(),
      getDeletedAttachments: jest.fn(() => []),
    }
  }),
}))
jest.unstable_mockModule('../creative_row_editor_delegated_clicks', () => ({
  createDelegatedClickHandler: jest.fn(() => jest.fn()),
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    archive,
    unarchive,
    save,
    get: jest.fn(() => Promise.resolve({})),
  },
}))
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  default: confirmDialog,
  confirmDialog,
  alertDialog,
  promptDialog: jest.fn(),
}))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')
const { buildEditorDom } = await import('./support/inline_editor_dom')

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

// Non-English on purpose: a literal baked into the module would fail the assertion.
const SAVE_FAILED_MESSAGE = '저장하지 못했습니다.'
const ARCHIVE_FAILED_MESSAGE = '아카이브하지 못했습니다.'
const RESTORE_FAILED_MESSAGE = '복원하지 못했습니다.'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

// data-description-raw-html / data-progress-value put openEditor() on
// loadCreative()'s synchronous cached-data path instead of an API fetch.
function rowMarkup(id) {
  return `
    <creative-tree-row creative-id="${id}" data-description-raw-html="hello" data-progress-value="0">
      <div class="creative-tree" id="creative-${id}" data-id="${id}" data-level="1"></div>
    </creative-tree-row>
  `
}

// Post-client-render state: tree_controller wiped #creatives and rendered rows
// into it, so only the out-of-container template holds a pristine placeholder.
function renderTree(rowIds, editorOverrides = {}) {
  document.body.innerHTML = `
    <template id="creatives-empty-state-template">${EMPTY_HTML}</template>
    <div id="creatives">${rowIds.map(rowMarkup).join('')}</div>
    <div id="center-frame"></div>
  `
  const template = buildEditorDom(document.getElementById('center-frame'), {
    saveFailedMessage: SAVE_FAILED_MESSAGE,
    archiveFailedMessage: ARCHIVE_FAILED_MESSAGE,
    restoreFailedMessage: RESTORE_FAILED_MESSAGE,
    ...editorOverrides,
  })
  initializeCreativeRowEditor()
  return template
}

// Binds the editor session to the row (currentTree) and leaves it dirty with a
// pending save, so archiving has to flush that save before dropping the row.
function openEditorWithPendingEdit(id) {
  document.getElementById('metadata-popup').style.display = 'none'
  const form = document.getElementById('inline-edit-form-element')
  form.action = `/creatives/${id}`
  document.getElementById('inline-method').value = 'patch'
  document.dispatchEvent(new CustomEvent('creative-edit-click', {
    detail: { treeElement: document.getElementById(`creative-${id}`) },
  }))
  editorOptions.onChange({ html: '<p>edited</p>', markdown: 'edited' })
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
  editorOptions = null
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

// Stimulus renders `data-controller="creatives--tree creatives--sync"` on #creatives,
// so the fixture carries both identifiers: an exact-match attribute selector for the
// first one alone does not match that, which is how the reload came to be skipped
// entirely in the browser.
function stubTreeController() {
  const treeEl = container()
  treeEl.setAttribute('data-controller', 'creatives--tree creatives--sync')
  treeEl.dataset.loaded = 'true'
  const requestReload = jest.fn()
  const load = jest.fn()
  window.Stimulus = {
    getControllerForElementAndIdentifier: jest.fn((el, identifier) =>
      el === treeEl && identifier === 'creatives--tree' ? { requestReload, load } : null,
    ),
  }
  return { treeEl, requestReload, load }
}

test('restoring an archived row asks the tree controller for an editing-aware reload', async () => {
  renderTree(['42'])
  document.querySelector('creative-tree-row[creative-id="42"]').setAttribute('archived', '')
  const { requestReload, load } = stubTreeController()

  await archiveCreative('42')

  expect(unarchive).toHaveBeenCalledWith('42')
  expect(archive).not.toHaveBeenCalled()
  expect(requestReload).toHaveBeenCalledTimes(1)
  // load() bypasses the controller's `_editing` guard, so it must not be used here.
  expect(load).not.toHaveBeenCalled()
})

// The unarchive request is in flight for an unbounded time, so the user can open
// another row and start typing before it lands. Wiping the container here would
// take that row — and the editor attached inside it — out of the document, losing
// the newer draft. Deciding when it is safe to re-render is the controller's job.
test('restoring an archived row does not wipe the tree itself', async () => {
  renderTree(['42'])
  document.querySelector('creative-tree-row[creative-id="42"]').setAttribute('archived', '')
  const { treeEl } = stubTreeController()

  await archiveCreative('42')

  expect(treeEl.querySelector('creative-tree-row')).not.toBeNull()
  expect(treeEl.dataset.loaded).toBe('true')
})

test('flushes a pending edit before dropping the archived row', async () => {
  renderTree(['42'])
  openEditorWithPendingEdit('42')

  await archiveCreative('42')

  expect(save).toHaveBeenCalledTimes(1)
  expect(container().querySelector('creative-tree-row')).toBeNull()
  expect(placeholder()).not.toBeNull()
})

// The pending edit is flushed before the archive request goes out, so a failed
// flush aborts the whole action while the server is still untouched. That is what
// makes the alert honest: it tells the user their edits are still open, and they
// are — the row stays, the editor stays on it with the draft, and nothing was
// archived. Doing it the other way round forced a choice between stranding the
// archived row on screen and silently discarding the draft.
test('does not archive when the pending save fails, and keeps the draft', async () => {
  const template = renderTree(['42'])
  save.mockRejectedValueOnce(new Error('network down'))
  openEditorWithPendingEdit('42')

  await archiveCreative('42')

  expect(save).toHaveBeenCalledTimes(1)
  expect(archive).not.toHaveBeenCalled()
  expect(container().querySelector('creative-tree-row')).not.toBeNull()
  expect(alertDialog).toHaveBeenCalledWith(SAVE_FAILED_MESSAGE)
  // The editor is still open on the row, holding the rejected draft.
  expect(template.style.display).toBe('block')
})

// The flush happens before the request, so by the time the request itself fails
// the editor is already closed and currentTree cleared. The row is untouched and
// the draft is safely on the server, but the handler used to `return` on a non-OK
// response and had no rejection handler at all, so the action just evaporated:
// editor unexpectedly closed, row still unarchived, nothing said.
test('alerts and leaves the row alone when the archive request returns non-OK', async () => {
  renderTree(['42'])
  archive.mockResolvedValueOnce({ ok: false })

  await archiveCreative('42')

  expect(archive).toHaveBeenCalledWith('42')
  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
  expect(alertDialog).toHaveBeenCalledWith(ARCHIVE_FAILED_MESSAGE)
})

// An unhandled rejection here fails the test run, which is the other half of
// what this covers.
test('alerts and leaves the row alone when the archive request rejects', async () => {
  renderTree(['42'])
  archive.mockRejectedValueOnce(new Error('network down'))

  await archiveCreative('42')

  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(alertDialog).toHaveBeenCalledWith(ARCHIVE_FAILED_MESSAGE)
})

test('alerts with the restore message and skips the reload when unarchive fails', async () => {
  renderTree(['42'])
  document.querySelector('creative-tree-row[creative-id="42"]').setAttribute('archived', '')
  const { treeEl, requestReload } = stubTreeController()
  unarchive.mockResolvedValueOnce({ ok: false })

  await archiveCreative('42')

  expect(requestReload).not.toHaveBeenCalled()
  expect(treeEl.dataset.loaded).toBe('true')
  expect(alertDialog).toHaveBeenCalledWith(RESTORE_FAILED_MESSAGE)
})

// Mirrors the save-failure alert: the string only exists in the ERB, so nothing
// is shown when the attribute is missing rather than falling back to a literal.
test('shows no alert when the localized archive failure message is absent', async () => {
  renderTree(['42'], { archiveFailedMessage: undefined, restoreFailedMessage: undefined })
  archive.mockResolvedValueOnce({ ok: false })

  await archiveCreative('42')

  expect(alertDialog).not.toHaveBeenCalled()
  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
})

// The pre-flush closes the editor before the request goes out, and the row stays
// on screen and clickable while it is in flight. Nothing stops the user reopening
// that very row and typing again — and the editor template is attached *inside*
// the row, so removing the row on success takes the newer draft out of the
// document with no flush and no feedback.
test('does not remove the archived row when the editor was reopened on it', async () => {
  const template = renderTree(['42'])
  const { requestReload } = stubTreeController()
  let settleArchive
  archive.mockReturnValueOnce(new Promise((resolve) => { settleArchive = resolve }))

  await archiveCreative('42')
  expect(archive).toHaveBeenCalledWith('42')

  // Still in flight: the user reopens the same row and starts a new draft.
  openEditorWithPendingEdit('42')

  settleArchive({ ok: true })
  await flush()
  await flush()

  expect(container().querySelector('creative-tree-row[creative-id="42"]')).not.toBeNull()
  expect(template.style.display).toBe('block')
  // Handed to the editing-aware reload instead, which holds the re-render until
  // the user closes the editor.
  expect(requestReload).toHaveBeenCalledTimes(1)
})

// The guard is about the draft, not about archiving being slow: an editor sitting
// on some other row is unaffected by removing this one, so that still happens
// immediately rather than waiting for the user to finish an unrelated edit.
test('still removes the archived row when the editor was reopened elsewhere', async () => {
  renderTree(['42', '43'])
  const { requestReload } = stubTreeController()
  let settleArchive
  archive.mockReturnValueOnce(new Promise((resolve) => { settleArchive = resolve }))

  await archiveCreative('42')
  openEditorWithPendingEdit('43')

  settleArchive({ ok: true })
  await flush()
  await flush()

  expect(container().querySelector('creative-tree-row[creative-id="42"]')).toBeNull()
  expect(container().querySelector('creative-tree-row[creative-id="43"]')).not.toBeNull()
  expect(requestReload).not.toHaveBeenCalled()
})

// Archiving a parent drops its children container too, so an editor reopened on a
// child row is in exactly the same danger as one on the row itself.
test('does not remove the archived subtree when the editor was reopened on a child', async () => {
  renderTree(['42'])
  container().insertAdjacentHTML('beforeend',
    `<div class="creative-children" id="creative-children-42">${
      '<creative-tree-row creative-id="99" data-description-raw-html="hi" data-progress-value="0">' +
      '<div class="creative-tree" id="creative-99" data-id="99" data-level="2"></div>' +
      '</creative-tree-row>'
    }</div>`)
  const { requestReload } = stubTreeController()
  let settleArchive
  archive.mockReturnValueOnce(new Promise((resolve) => { settleArchive = resolve }))

  await archiveCreative('42')
  openEditorWithPendingEdit('99')

  settleArchive({ ok: true })
  await flush()
  await flush()

  expect(document.getElementById('creative-children-42')).not.toBeNull()
  expect(container().querySelector('creative-tree-row[creative-id="42"]')).not.toBeNull()
  expect(requestReload).toHaveBeenCalledTimes(1)
})

test('declining the archive confirmation leaves the row in place', async () => {
  confirmDialog.mockResolvedValueOnce(false)
  renderTree(['42'])

  await archiveCreative('42')

  expect(archive).not.toHaveBeenCalled()
  expect(container().querySelectorAll('creative-tree-row')).toHaveLength(1)
  expect(placeholder()).toBeNull()
})
