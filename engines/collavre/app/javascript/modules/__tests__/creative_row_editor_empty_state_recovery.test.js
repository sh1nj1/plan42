/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// The real inline editor is a JSX module (untransformed in Jest), so it is
// stubbed. The delegated click handler stays REAL here: the empty-state Add
// button reaches startNew() through it, and hiding the empty-state card is part
// of that path.
const createInlineEditorMock = jest.fn()
const saveMock = jest.fn()
const alertDialogMock = jest.fn(() => Promise.resolve())

jest.unstable_mockModule('../lexical_inline_editor', () => ({
  createInlineEditor: createInlineEditorMock,
}))
jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: {
    save: saveMock,
    get: jest.fn(() => Promise.resolve({})),
    children: jest.fn(() => Promise.resolve([])),
  },
}))
// creativesApi.save bypasses the api queue, so a failure here can only be
// surfaced by an explicit alertDialog() call from the editor.
jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  alertDialog: alertDialogMock,
  confirmDialog: jest.fn(() => Promise.resolve(true)),
  promptDialog: jest.fn(() => Promise.resolve(null)),
}))

const { initializeCreativeRowEditor } = await import('../creative_row_editor')

const {
  buildEditorDom, defineTreeRowStub, renderEmptyState, appendExistingRow, flush,
} = await import('./support/inline_editor_dom')

// Stands in for t('collavre.creatives.index.save_failed_alert'); deliberately
// not English so a hardcoded literal in the module would fail the assertion.
const SAVE_FAILED_MESSAGE = '저장하지 못했습니다'

describe('empty-state recovery when the first inline save fails', () => {
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
    buildEditorDom(document.getElementById('center-frame'), { saveFailedMessage: SAVE_FAILED_MESSAGE })
    initializeCreativeRowEditor()
    document.getElementById('metadata-popup').style.display = 'none'
  })

  async function startFirstRowWithContent() {
    const emptyState = renderEmptyState()
    emptyState.querySelector('.new-root-creative-btn').click()
    await flush()

    // Typing marks the buffer dirty so hideCurrent() actually attempts a save.
    const description = document.getElementById('inline-creative-description')
    description.value = '<p>first creative</p>'
    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'first creative'
    textarea.dispatchEvent(new Event('input'))

    return emptyState
  }

  function unsavedRowTree() {
    const rows = Array.from(document.querySelectorAll('#creatives creative-tree-row'))
    const unsaved = rows.find((el) => !el.querySelector('.creative-row'))
    return unsaved ? unsaved.querySelector('.creative-tree') : null
  }

  function saveStatus() {
    return document.getElementById('inline-save-status').dataset.state
  }

  test('hides the empty state while the first inline row is being created', async () => {
    const emptyState = await startFirstRowWithContent()

    expect(emptyState.style.display).toBe('none')
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
  })

  test('keeps the failed first draft and its editor open when the save rejects on close', async () => {
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    const emptyState = await startFirstRowWithContent()

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    // The draft is the user's only copy of what they typed, so it must survive
    // the failure. The row therefore stays and the empty-state card stays hidden
    // behind it — the editor is visible on top of it, so nothing is blank.
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    expect(emptyState.style.display).toBe('none')

    const template = document.getElementById('inline-edit-form')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(unsavedRowTree())
    expect(saveStatus()).toBe('error')
  })

  test('submits the observed history anchor and editing-session token', async () => {
    document.getElementById('inline-history-anchor-id').value = '42'
    document.getElementById('inline-change-group-token').value = 'edit-session-1'
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    await startFirstRowWithContent()

    document.getElementById('inline-close').click()
    await flush()

    const submittedForm = saveMock.mock.calls[0][2]
    const submittedData = new FormData(submittedForm)
    expect(submittedData.get('history_anchor_id')).toBe('42')
    expect(submittedData.get('change_group_token')).toBe('edit-session-1')
  })

  test('keeps the failed first draft when the save resolves with a non-ok response', async () => {
    saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
    const emptyState = await startFirstRowWithContent()

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    expect(emptyState.style.display).toBe('none')

    const template = document.getElementById('inline-edit-form')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(unsavedRowTree())
    expect(saveStatus()).toBe('error')
  })

  test('re-arms the pending save so closing again retries the failed first draft', async () => {
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    await startFirstRowWithContent()

    document.getElementById('inline-close').click()
    await flush()
    expect(saveMock).toHaveBeenCalledTimes(1)

    document.getElementById('inline-close').click()
    await flush()
    expect(saveMock).toHaveBeenCalledTimes(2)
  })

  test('abandons the row switch and keeps the draft when the first save fails', async () => {
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    const emptyState = await startFirstRowWithContent()
    const { tree: existingTree, row: existingRow } = appendExistingRow(42)

    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: existingTree } }))
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    // The switch must not go through: opening the other row would run
    // loadCreative() over the shared form buffer, destroying the draft.
    const draftTree = unsavedRowTree()
    expect(draftTree).not.toBeNull()
    const template = document.getElementById('inline-edit-form')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(draftTree)
    expect(saveStatus()).toBe('error')
    // The row the user clicked stays untouched — still rendered, not edited.
    expect(existingRow.style.display).toBe('')
    expect(existingTree.contains(template)).toBe(false)
    // Real rows remain, so the empty-state card must stay hidden.
    expect(emptyState.style.display).toBe('none')
    // The aborted click would otherwise look like it did nothing.
    expect(alertDialogMock).toHaveBeenCalledTimes(1)
    expect(alertDialogMock.mock.calls[0][0]).toBe(SAVE_FAILED_MESSAGE)
  })

  test('abandons the switch and keeps an existing row edit when its save fails', async () => {
    const { tree: firstTree, row: firstRow } = appendExistingRow(42)
    const { tree: secondTree, row: secondRow } = appendExistingRow(43)

    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: firstTree } }))
    await flush()

    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'edited but never persisted'
    textarea.dispatchEvent(new Event('input'))

    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: secondTree } }))
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    // The rejected PATCH means the server still holds the old copy; the buffer
    // is the only place the user's edit exists, so the editor must stay on the
    // outgoing row instead of loading creative 43 over it.
    const template = document.getElementById('inline-edit-form')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(firstTree)
    expect(firstRow.style.display).toBe('none')
    expect(secondRow.style.display).toBe('')
    expect(saveStatus()).toBe('error')
    expect(alertDialogMock).toHaveBeenCalledTimes(1)
    expect(alertDialogMock.mock.calls[0][0]).toBe(SAVE_FAILED_MESSAGE)
  })

  test('does not start another new row when the outgoing draft fails to save', async () => {
    const { tree: existingTree } = appendExistingRow(42)
    // `.append-parent-btn` is the route into startNew() that does not
    // toggle-close the editor first — the add buttons return early when the
    // template is already open, so they never reach the switching flush.
    const appendBtn = document.createElement('button')
    appendBtn.type = 'button'
    appendBtn.className = 'append-parent-btn'
    appendBtn.dataset.childId = '42'
    document.body.appendChild(appendBtn)

    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: existingTree } }))
    await flush()
    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'edited but never persisted'
    textarea.dispatchEvent(new Event('input'))

    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    appendBtn.click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    // No second row: startNew() aborted instead of moving the shared template
    // onto a brand-new row and stranding the rejected draft.
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
    const template = document.getElementById('inline-edit-form')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(existingTree)
    expect(saveStatus()).toBe('error')
    expect(alertDialogMock.mock.calls[0][0]).toBe(SAVE_FAILED_MESSAGE)
  })

  test('omits the alert when no localized message is available', async () => {
    delete document.getElementById('inline-edit-form-element').dataset.saveFailedMessage
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    await startFirstRowWithContent()
    const { tree: existingTree } = appendExistingRow(42)

    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: existingTree } }))
    await flush()

    // No English fallback baked into the module.
    expect(alertDialogMock).not.toHaveBeenCalled()
    expect(saveStatus()).toBe('error')
  })

  test('still restores the empty state when the blank first row is cancelled', async () => {
    const emptyState = renderEmptyState()
    emptyState.querySelector('.new-root-creative-btn').click()
    await flush()

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).not.toHaveBeenCalled()
    expect(emptyState.style.display).toBe('')
    expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(0)
  })

  test('keeps an existing row in the editor when closing it fails to save', async () => {
    saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
    const { tree, row } = appendExistingRow(42)

    document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
    await flush()
    expect(row.style.display).toBe('none')

    const textarea = document.getElementById('markdown-editor-textarea')
    textarea.value = 'edited'
    textarea.dispatchEvent(new Event('input'))

    document.getElementById('inline-close').click()
    await flush()

    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(document.getElementById('creative-42')).not.toBeNull()
    // Closing must not discard the rejected edit either: the editor stays open
    // on the row (so the rendered row stays hidden underneath) with the save
    // re-armed, rather than reverting to the stale server copy.
    const template = document.getElementById('inline-edit-form')
    expect(template.style.display).toBe('block')
    expect(template.parentElement).toBe(tree)
    expect(row.style.display).toBe('none')
    expect(saveStatus()).toBe('error')
    // Not a switch — the visible error status is the feedback, no modal.
    expect(alertDialogMock).not.toHaveBeenCalled()
  })

  // hideCurrent() has to announce that editing stopped, but *when* decides
  // whether the draft survives. It used to announce it up front, before
  // awaiting the save it is about to flush. Everything that defers work while a
  // row is being edited — the tree controller holds a reload and drains it on
  // that stop, then waits out a 300ms debounce — therefore got the all-clear
  // while the editor was still holding the user's text. A save slower than that
  // debounce let the reload replace the whole container, taking the row and the
  // editor attached inside it out of the document; recoverFromFailedSave() then
  // re-attached the editor to a row that was no longer in the page. The row is
  // released only once the flush has actually succeeded.
  describe('editing presence across the flush', () => {
    function recordPresence() {
      const events = []
      const record = (event) => events.push(`${event.type}:${event.detail?.creativeId}`)
      document.addEventListener('creative-editing:start', record)
      document.addEventListener('creative-editing:stop', record)
      return {
        events,
        stop: () => {
          document.removeEventListener('creative-editing:start', record)
          document.removeEventListener('creative-editing:stop', record)
        },
      }
    }

    async function closeRowWithEdit(id = 42) {
      const { tree } = appendExistingRow(id)
      document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
      await flush()

      const textarea = document.getElementById('markdown-editor-textarea')
      textarea.value = 'edited'
      textarea.dispatchEvent(new Event('input'))

      document.getElementById('inline-close').click()
      await flush()
      return tree
    }

    test('holds the stop until an in-flight flush settles', async () => {
      let settleSave
      saveMock.mockImplementation(() => new Promise((resolve) => { settleSave = resolve }))
      const presence = recordPresence()

      try {
        await closeRowWithEdit()

        // The save is still in flight and the editor still owns the row, so
        // nothing may act on "editing stopped" yet.
        expect(presence.events).toEqual(['creative-editing:start:42'])

        settleSave({ ok: true, text: () => Promise.resolve('{}') })
        await flush()

        expect(presence.events).toEqual([
          'creative-editing:start:42',
          'creative-editing:stop:42',
        ])
      } finally {
        presence.stop()
      }
    })

    test('blocks opening another row while the close flush is in flight', async () => {
      let rejectSave
      saveMock.mockImplementation(() => new Promise((_, reject) => { rejectSave = reject }))
      const { tree: firstTree } = appendExistingRow(42)
      const { tree: secondTree, row: secondRow } = appendExistingRow(43)

      document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: firstTree } }))
      await flush()
      document.getElementById('inline-creative-description').value = '<p>outgoing draft</p>'
      const textarea = document.getElementById('markdown-editor-textarea')
      textarea.value = 'outgoing draft'
      textarea.dispatchEvent(new Event('input'))

      document.getElementById('inline-close').click()
      await flush()
      document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: secondTree } }))
      await flush()

      const template = document.getElementById('inline-edit-form')
      expect(template.parentElement).toBe(firstTree)
      expect(template.style.display).toBe('none')
      expect(secondRow.style.display).toBe('')

      rejectSave(new Error('network down'))
      await flush()

      expect(template.parentElement).toBe(firstTree)
      expect(template.style.display).toBe('block')
      expect(document.getElementById('inline-creative-description').value).toBe('<p>outgoing draft</p>')
    })

    test('blocks starting a new row while the close flush is in flight', async () => {
      let settleSave
      saveMock.mockImplementation(() => new Promise((resolve) => { settleSave = resolve }))
      const { tree } = appendExistingRow(42)
      const addButton = document.createElement('button')
      addButton.type = 'button'
      addButton.className = 'new-root-creative-btn'
      document.body.appendChild(addButton)

      document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
      await flush()
      document.getElementById('inline-creative-description').value = '<p>outgoing draft</p>'
      const textarea = document.getElementById('markdown-editor-textarea')
      textarea.value = 'outgoing draft'
      textarea.dispatchEvent(new Event('input'))

      document.getElementById('inline-close').click()
      await flush()
      addButton.click()
      await flush()

      expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)

      settleSave({ ok: true, text: () => Promise.resolve('{}') })
      await flush()

      expect(document.querySelectorAll('#creatives creative-tree-row')).toHaveLength(1)
      expect(document.getElementById('inline-edit-form').style.display).toBe('none')
    })

    test('never announces the stop when the flush is rejected', async () => {
      saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
      const presence = recordPresence()

      try {
        await closeRowWithEdit()

        // The editor is back on the row with the rejected draft, so the row was
        // never released — announcing a stop here would both tell collaborators
        // it is free and let a deferred reload delete what is still open in it.
        expect(presence.events).toEqual(['creative-editing:start:42'])
      } finally {
        presence.stop()
      }
    })

    test('never announces the stop when the flush comes back non-OK', async () => {
      saveMock.mockImplementation(() => Promise.resolve({ ok: false, status: 500 }))
      const presence = recordPresence()

      try {
        await closeRowWithEdit()

        expect(presence.events).toEqual(['creative-editing:start:42'])
      } finally {
        presence.stop()
      }
    })

    test('holds the stop when the flush is reached through the add button', async () => {
      let settleSave
      saveMock.mockImplementation(() => new Promise((resolve) => { settleSave = resolve }))
      const presence = recordPresence()

      try {
        const { tree } = appendExistingRow(42)
        document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
        await flush()

        const textarea = document.getElementById('markdown-editor-textarea')
        textarea.value = 'edited'
        textarea.dispatchEvent(new Event('input'))

        // addNew() used to announce the stop itself, before handing the flush to
        // startNew() → hideCurrent(), which reopened the very window this closes.
        document.getElementById('inline-add').click()
        await flush()

        expect(presence.events).toEqual(['creative-editing:start:42'])

        settleSave({ ok: true, text: () => Promise.resolve('{}') })
        await flush()

        expect(presence.events.slice(0, 2)).toEqual([
          'creative-editing:start:42',
          'creative-editing:stop:42',
        ])
      } finally {
        presence.stop()
      }
    })

    test('keeps a never-persisted draft announced as being edited', async () => {
      saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
      const presence = recordPresence()

      try {
        await startFirstRowWithContent()
        document.getElementById('inline-close').click()
        await flush()

        // startNew() announces the row with a null id and there is nothing to
        // ping for, so a stop here could never be taken back: the deferred
        // reload would fire on a draft that only exists in the editor.
        expect(presence.events).toEqual(['creative-editing:start:null'])
      } finally {
        presence.stop()
      }
    })

    test('keeps the periodic ping running through a failed flush', async () => {
      jest.useFakeTimers()
      saveMock.mockImplementation(() => Promise.reject(new Error('network down')))
      const { tree } = appendExistingRow(42)
      const presence = recordPresence()

      try {
        document.dispatchEvent(new CustomEvent('creative-edit-click', { detail: { treeElement: tree } }))
        await jest.advanceTimersByTimeAsync(20)

        const textarea = document.getElementById('markdown-editor-textarea')
        textarea.value = 'edited'
        textarea.dispatchEvent(new Event('input'))

        document.getElementById('inline-close').click()
        await jest.advanceTimersByTimeAsync(20)

        const beforeTick = presence.events.length
        await jest.advanceTimersByTimeAsync(3100)
        expect(presence.events.slice(beforeTick)).toEqual(['creative-editing:start:42'])
      } finally {
        presence.stop()
        jest.useRealTimers()
      }
    })
  })
})
