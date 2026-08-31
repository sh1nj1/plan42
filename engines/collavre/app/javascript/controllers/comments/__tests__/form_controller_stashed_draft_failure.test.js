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

// Drives the real handleSend() so the failure path is exercised end to end:
// resetForm() only runs on success, so a failed send leaves the submitted text
// sitting in the box, and _restoreStashedDraft has to tell that apart from text
// the user typed while the request was in flight.
// handleSend guards duplicate submits through a module-scope Set keyed by
// creative id, so each test gets its own id rather than leaking state.
let creativeSeq = 0

const buildController = () => {
  creativeSeq += 1
  document.head.innerHTML = '<meta name="csrf-token" content="tok">'
  document.body.innerHTML = `
    <div id="comments-popup">
      <form id="new-comment-form"><textarea name="comment[content]"></textarea></form>
    </div>
  `
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
  Object.defineProperty(controller, 'element', { get: () => document.getElementById('comments-popup') })
  Object.defineProperty(controller, 'textareaTarget', { get: () => textarea })
  Object.defineProperty(controller, 'formTarget', { get: () => form })
  Object.defineProperty(controller, 'listController', { get: () => listCtrl })
  Object.defineProperty(controller, 'presenceController', { get: () => null })
  controller.creativeId = `c${creativeSeq}`
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

const failedResponse = () => ({
  ok: false,
  status: 500,
  json: () => Promise.resolve({ errors: [ 'Unable to save comment' ] }),
})

const COMMAND_TEXT = '/calendar 2026-08-14 10:00 Sync'

describe('CommentsFormController stashed draft across a send failure', () => {
  beforeEach(() => {
    global.fetch = jest.fn()
    alertDialog.mockReset().mockResolvedValue()
  })

  test('restores the draft over the command text a failed send left behind', async () => {
    const { controller, textarea } = buildController()
    global.fetch.mockResolvedValue(failedResponse())

    // command_menu.js hands the draft over, overwrites the box with the
    // command, and clicks send.
    stash(controller, 'roadmap notes')
    textarea.value = COMMAND_TEXT

    controller.handleSend(new Event('submit'))
    await flush()

    expect(alertDialog).toHaveBeenCalledTimes(1)
    // resetForm() never ran, so the box still holds COMMAND_TEXT — untouched by
    // the user, and therefore safe to hand the draft back into.
    expect(textarea.value).toBe('roadmap notes')
    expect(controller.resetForm).not.toHaveBeenCalled()
  })

  test('does not clobber text typed while the failing command was in flight', async () => {
    const { controller, textarea } = buildController()
    let settle
    global.fetch.mockReturnValue(new Promise((resolve) => { settle = resolve }))

    stash(controller, 'roadmap notes')
    textarea.value = COMMAND_TEXT
    controller.handleSend(new Event('submit'))

    textarea.value = 'a different message'
    settle(failedResponse())
    await flush()

    expect(textarea.value).toBe('a different message')
  })

  test('still restores the draft into the box a successful send cleared', async () => {
    const { controller, textarea } = buildController()
    const settled = jest.fn()
    controller.element.addEventListener('comments--form:submit-settled', settled)
    global.fetch.mockResolvedValue({ ok: true, text: () => Promise.resolve('<div></div>') })

    stash(controller, 'roadmap notes')
    textarea.value = COMMAND_TEXT

    controller.handleSend(new Event('submit'))
    await flush()

    expect(controller.resetForm).toHaveBeenCalledTimes(1)
    expect(textarea.value).toBe('roadmap notes')
    expect(settled).toHaveBeenCalledTimes(1)
  })

  test('a failure with nothing stashed leaves the submitted text for a retry', async () => {
    const { controller, textarea } = buildController()
    global.fetch.mockResolvedValue(failedResponse())

    textarea.value = 'an ordinary message'
    controller.handleSend(new Event('submit'))
    await flush()

    expect(textarea.value).toBe('an ordinary message')
  })

  test('announces settlement only after the failure dialog is dismissed', async () => {
    const { controller, textarea } = buildController()
    const settled = jest.fn()
    let dismissDialog
    controller.element.addEventListener('comments--form:submit-settled', settled)
    global.fetch.mockResolvedValue(failedResponse())
    alertDialog.mockReturnValue(new Promise((resolve) => { dismissDialog = resolve }))

    textarea.value = COMMAND_TEXT
    controller.handleSend(new Event('submit'))
    await flush()

    expect(alertDialog).toHaveBeenCalledTimes(1)
    expect(settled).not.toHaveBeenCalled()

    dismissDialog()
    await flush()

    expect(settled).toHaveBeenCalledTimes(1)
  })
})
