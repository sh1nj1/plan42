/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

describe('CommentsListController read pointer updates', () => {
  let controller
  let topicsController

  beforeEach(() => {
    jest.useFakeTimers()
    document.head.innerHTML = '<meta name="csrf-token" content="test-csrf">'
    topicsController = { loadTopics: jest.fn() }
    controller = Object.create(CommentsListController.prototype)
    controller.creativeId = '42'
    Object.defineProperty(controller, 'element', { value: document.createElement('div') })
    document.body.appendChild(controller.element)
    Object.defineProperty(controller, 'popupController', { value: { topicsController } })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    jest.useRealTimers()
    jest.clearAllMocks()
  })

  test('reloads topic unread counts after a successful read pointer update', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true })

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(global.fetch).toHaveBeenCalledWith('/comment_read_pointers/update', expect.objectContaining({ method: 'POST' }))
    expect(topicsController.loadTopics).toHaveBeenCalledTimes(1)
  })

  test('does not reload topic unread counts after a failed read pointer update', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false })

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(topicsController.loadTopics).not.toHaveBeenCalled()
  })
})
