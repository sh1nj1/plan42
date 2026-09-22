/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import CommentController from '../comment_controller'

afterEach(() => {
  document.body.innerHTML = ''
  delete document.body.dataset.currentUserId
  delete document.body.dataset.systemAdmin
  jest.restoreAllMocks()
})

test.each([
  ['gate approver', true, false, '42', true, true],
  ['gate admin approver', true, true, '42', true, true],
  ['other gate admin', true, true, '99', true, false],
  ['other gate reader', true, false, '99', true, false],
  ['anonymous reader', true, false, '', true, false],
  ['decided gate', true, true, '42', false, false],
  ['ordinary approval admin', false, true, '99', true, true],
  ['ordinary approval approver', false, false, '42', true, true],
  ['ordinary approval reader', false, false, '99', true, false]
])('%s sees only permitted controls', (_name, gate, admin, userId, pending, visible) => {
  document.body.dataset.currentUserId = userId
  document.body.dataset.systemAdmin = String(admin)
  document.body.innerHTML = `<div data-approval-gate="${gate}" data-approver-id="42" data-has-pending-action="${pending}">
    <button class="comment-approve-hidden" data-kind="approve"></button>
    <button class="comment-approve-hidden" data-kind="deny"></button>
    <textarea class="comment-approve-hidden" data-kind="reason"></textarea>
  </div>`
  const element = document.body.firstElementChild
  const controller = Object.create(CommentController.prototype)
  Object.defineProperties(controller, {
    element: { value: element },
    ownerButtonTargets: { value: [] },
    deleteButtonTargets: { value: [] },
    approveButtonTargets: { value: [element.querySelector('[data-kind="approve"]')] },
    denyButtonTargets: { value: [element.querySelector('[data-kind="deny"]')] },
    actionApproveControlsTargets: { value: [element.querySelector('[data-kind="reason"]')] }
  })
  controller.connect()
  for (const control of element.children) {
    expect(control.classList.contains('comment-approve-hidden')).toBe(!visible)
  }
  document.removeEventListener('mouseup', controller.handleMouseUp)
})
