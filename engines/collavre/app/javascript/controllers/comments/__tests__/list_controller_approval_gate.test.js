/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import ListController from '../list_controller'
import { approvalRequestOptions } from '../approval_request_options'

beforeEach(() => {
  document.head.innerHTML = '<meta name="csrf-token" content="csrf">'
  document.body.innerHTML = '<div class="comment-item" id="comment_42"><button data-comment-id="42"></button><textarea data-approval-reason>Revise first</textarea></div>'
})

afterEach(() => {
  jest.restoreAllMocks()
  document.body.innerHTML = ''
})

test.each(['approve', 'deny'])('%s submits the reason and replaces the decided comment', async action => {
  const controller = Object.create(ListController.prototype)
  controller.creativeId = '7'
  controller.topicQueryString = () => '?topic_id=3'
  global.fetch = jest.fn().mockResolvedValue({ ok: true, text: async () => '<div id="comment_42">Decided</div>' })
  const button = document.querySelector('button')
  button.classList.add(`${action}-comment-btn`)
  const event = { target: button, preventDefault: jest.fn() }
  controller.handleClick(event)
  controller.handleClick(event)
  expect(event.preventDefault).toHaveBeenCalledTimes(2)
  await new Promise(resolve => setTimeout(resolve, 0))
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(fetch).toHaveBeenCalledWith(`/creatives/7/comments/42/${action}?topic_id=3`, expect.objectContaining({
    method: 'POST', body: JSON.stringify({ reason: 'Revise first' }),
    headers: { 'X-CSRF-Token': 'csrf', 'Content-Type': 'application/json', 'Accept': 'text/html' }
  }))
  expect(document.querySelector('#comment_42').textContent).toBe('Decided')
})

test('existing approvals without a reason field still submit', () => {
  document.querySelector('textarea').remove()
  expect(approvalRequestOptions(document.querySelector('button')).body).toBe('{}')
})
