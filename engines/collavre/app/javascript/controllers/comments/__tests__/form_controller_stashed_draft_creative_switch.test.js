/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const alertDialog = jest.fn(() => Promise.resolve())
const confirmDialog = jest.fn(() => Promise.resolve(true))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({
  alertDialog,
  confirmDialog,
  promptDialog: jest.fn(),
  default: confirmDialog,
}))

const { default: CommentsFormController } = await import('../form_controller')

// The popup keeps one comments--form controller for every conversation:
// switching creatives calls onPopupOpened on this same instance, with no
// disconnect in between (see presence_controller.js — _navigateToEntry reuses
// open()/openForCreative(), so onPopupClosed does not even run). A command send
// that settles after such a switch must not hand the previous conversation's
// draft to the new one.
let creativeSeq = 0

const buildController = () => {
  creativeSeq += 1
  document.head.innerHTML = '<meta name="csrf-token" content="tok">'
  document.body.innerHTML = `
    <div id="comments-popup">
      <form id="new-comment-form"><textarea name="comment[content]"></textarea></form>
    </div>
  `
  const element = document.getElementById('comments-popup')
  const textarea = document.querySelector('textarea')
  const form = document.getElementById('new-comment-form')

  const listCtrl = {
    allNewerLoaded: true,
    manualSearchQuery: null,
    resetToLatest: jest.fn(),
    scrollToBottom: jest.fn(),
    updateStickiness: jest.fn(),
    markCommentsRead: jest.fn(),
  }

  const controller = Object.create(CommentsFormController.prototype)
  Object.defineProperty(controller, 'element', { get: () => element })
  Object.defineProperty(controller, 'textareaTarget', { get: () => textarea })
  Object.defineProperty(controller, 'formTarget', { get: () => form })
  Object.defineProperty(controller, 'listController', { get: () => listCtrl })
  Object.defineProperty(controller, 'presenceController', { get: () => null })
  controller.creativeId = `a${creativeSeq}`
  controller.editingId = null
  controller._reviewStore = { hasActive: false, isEmpty: true, hasBackup: () => false }
  controller.currentImageFiles = () => []
  controller.setSendingState = jest.fn()
  controller._autoResize = jest.fn()
  controller._updateSubmitButton = jest.fn()
  controller.renderCommentHtml = jest.fn()
  controller.resetForm = jest.fn(() => {
    textarea.value = ''
  })
  controller.shouldAutoFocusOnOpen = () => false

  return { controller, textarea }
}

const stash = (controller, draft) => {
  controller.handleStashDraft(
    new CustomEvent('comments--form:stash-draft', { detail: { draft } }),
  )
}

const flush = async () => {
  for (let i = 0; i < 5; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const okResponse = () => ({ ok: true, text: () => Promise.resolve('<div></div>') })

const COMMAND_TEXT = '/calendar 2026-08-14 10:00 Sync'

describe('CommentsFormController stashed draft across a creative switch', () => {
  beforeEach(() => {
    global.fetch = jest.fn()
    alertDialog.mockClear()
  })

  test('does not restore the draft into a different creative', async () => {
    const { controller, textarea } = buildController()
    let settle
    global.fetch.mockReturnValue(new Promise((resolve) => { settle = resolve }))

    stash(controller, 'roadmap notes')
    textarea.value = COMMAND_TEXT
    controller.handleSend(new Event('submit'))

    // The user leaves for another conversation while the command is in flight.
    controller.onPopupOpened({ creativeId: 'b-other', canComment: true })
    expect(textarea.value).toBe('')

    settle(okResponse())
    await flush()

    expect(textarea.value).toBe('')
    expect(controller._stashedDraft).toBeNull()
  })

  test('still restores the draft when the same creative is reopened mid-flight', async () => {
    const { controller, textarea } = buildController()
    const creativeId = controller.creativeId
    let settle
    global.fetch.mockReturnValue(new Promise((resolve) => { settle = resolve }))

    stash(controller, 'roadmap notes')
    textarea.value = COMMAND_TEXT
    controller.handleSend(new Event('submit'))

    // Reopening the same conversation (e.g. via a permalink) is not a switch.
    controller.onPopupOpened({ creativeId, canComment: true })

    settle(okResponse())
    await flush()

    expect(textarea.value).toBe('roadmap notes')
  })

  test('an id that changes type across reopen still counts as the same creative', async () => {
    // onPopupOpened is called with whatever the caller holds — popup_controller
    // reads it from a dataset (string), tests and some callers pass a number.
    const { controller, textarea } = buildController()
    controller.creativeId = 42
    let settle
    global.fetch.mockReturnValue(new Promise((resolve) => { settle = resolve }))

    stash(controller, 'roadmap notes')
    textarea.value = COMMAND_TEXT
    controller.handleSend(new Event('submit'))

    controller.onPopupOpened({ creativeId: '42', canComment: true })

    settle(okResponse())
    await flush()

    expect(textarea.value).toBe('roadmap notes')
  })

  test('a stash left behind by a bailed send is not restored in another creative', () => {
    // handleSend returns early when a send for the same creative is already in
    // flight, so .finally() never runs and the stash outlives it. The next send
    // consumes it — and by then the user may be somewhere else entirely.
    const { controller, textarea } = buildController()

    stash(controller, 'roadmap notes')
    controller.creativeId = 'b-other'

    textarea.value = ''
    controller._restoreStashedDraft('')

    expect(textarea.value).toBe('')
    expect(controller._stashedDraft).toBeNull()
  })
})
