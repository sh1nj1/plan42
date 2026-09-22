/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const alertDialog = jest.fn()
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }))
const { installResendAction, installSelectionActions, resendSelectedMessage } = await import('../resend_action')

let controller, bar
beforeEach(() => {
  document.body.innerHTML = '<div id="comment_10" data-user-id="1" data-ai-user="false"></div><div id="popup"></div>'
  document.body.dataset.currentUserId = '1'
  controller = {
    selection: new Set(['10']), creativeId: '7', element: document.getElementById('popup'),
    clearSelection: jest.fn(), loadInitialComments: jest.fn(), updateSelectionActionBar: jest.fn()
  }
  Object.assign(controller.element.dataset, { resendLabel: '다시 보내기', resendDescription: '설명', resendFailed: '실패' })
  bar = document.createElement('div')
  bar.innerHTML = '<button class="selection-action-bar-close"></button>'
  global.fetch = jest.fn()
  alertDialog.mockClear()
})

function button() {
  installResendAction(controller, bar)
  return bar.querySelector('.selection-action-resend')
}

test('enables a single own message and uses localized text', () => {
  const action = button()
  expect(action.disabled).toBe(false)
  expect(action.textContent).toBe('다시 보내기')
  expect(action.title).toBe('설명')
})

test.each(['multiple', 'none', 'other', 'ai', 'missing', 'anonymous', 'busy'])('disables resend for %s', reason => {
  if (reason === 'multiple') controller.selection.add('11')
  if (reason === 'none') controller.selection.clear()
  if (reason === 'other') document.getElementById('comment_10').dataset.userId = '2'
  if (reason === 'ai') document.getElementById('comment_10').dataset.aiUser = 'true'
  if (reason === 'missing') document.getElementById('comment_10').remove()
  if (reason === 'anonymous') delete document.body.dataset.currentUserId
  if (reason === 'busy') controller.resendingComment = true
  expect(button().disabled).toBe(true)
})

test('posts once during a pending request and refreshes after success', async () => {
  let resolve
  fetch.mockReturnValue(new Promise(done => { resolve = done }))
  const action = button()
  const first = resendSelectedMessage(controller, action)
  await resendSelectedMessage(controller, action)
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(fetch.mock.calls[0][0]).toBe('/creatives/7/comments/10/resend')
  expect(fetch.mock.calls[0][1].method).toBe('POST')
  expect(action.disabled).toBe(true)
  resolve({ ok: true })
  await first
  expect(controller.clearSelection).toHaveBeenCalledTimes(1)
  expect(controller.loadInitialComments).toHaveBeenCalledTimes(1)
  expect(controller.resendingComment).toBe(false)
})

test.each(['server', 'network', 'invalid-json'])('preserves selection and restores actions on %s failure', async kind => {
  if (kind === 'network') fetch.mockRejectedValue(new Error('Offline'))
  else fetch.mockResolvedValue({ ok: false, json: kind === 'server' ? async () => ({ error: 'Forbidden' }) : async () => { throw new Error() } })
  await resendSelectedMessage(controller, button())
  expect(controller.clearSelection).not.toHaveBeenCalled()
  expect(controller.loadInitialComments).not.toHaveBeenCalled()
  expect(controller.resendingComment).toBe(false)
  expect(controller.updateSelectionActionBar).toHaveBeenCalled()
  expect(alertDialog).toHaveBeenCalled()
})

test('rechecks ownership when invoked', async () => {
  const action = button()
  document.body.dataset.currentUserId = '2'
  await resendSelectedMessage(controller, action)
  expect(fetch).not.toHaveBeenCalled()
})

test('does not clear the new topic selection when the request finishes after navigation', async () => {
  let resolve
  fetch.mockReturnValue(new Promise(done => { resolve = done }))
  const pending = resendSelectedMessage(controller, button())
  controller.currentTopicId = '99'
  resolve({ ok: true })
  await pending
  expect(controller.clearSelection).not.toHaveBeenCalled()
  expect(controller.loadInitialComments).not.toHaveBeenCalled()
})

test('button click sends the selected message', async () => {
  fetch.mockResolvedValue({ ok: true })
  button().click()
  await Promise.resolve()
  expect(fetch).toHaveBeenCalledTimes(1)
})


test('keeps existing selection actions wired alongside resend', () => {
  const actions = { delete: 'deleteSelectedComments', merge: 'mergeSelectedComments', move: 'openMoveModal', topic: 'openTopicSearchPopup', branch: 'branchSelectedComments' }
  for (const [name, method] of Object.entries(actions)) {
    controller[method] = jest.fn()
    const action = document.createElement('button')
    action.className = `selection-action-${name}`
    bar.append(action)
  }
  installSelectionActions(controller, bar)
  for (const [name, method] of Object.entries(actions)) {
    bar.querySelector(`.selection-action-${name}`).click()
    expect(controller[method]).toHaveBeenCalledTimes(1)
  }
  bar.querySelector('.selection-action-bar-close').click()
  expect(controller.clearSelection).toHaveBeenCalledTimes(1)
})

test('uses localized fallback when a network error has no message', async () => {
  fetch.mockRejectedValue(new Error())
  await resendSelectedMessage(controller, button())
  expect(alertDialog).toHaveBeenCalledWith('실패')
})
