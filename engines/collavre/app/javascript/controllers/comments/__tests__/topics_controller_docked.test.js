/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsTopicsController from '../topics_controller'

describe('CommentsTopicsController docked lifecycle', () => {
  test('does not render a topics response that arrives after the popup closes', async () => {
    const controller = Object.create(CommentsTopicsController.prototype)
    let finishRequest
    controller.creativeIdValue = '123'
    controller._loadTopicsVersion = 0
    Object.defineProperty(controller, 'element', { value: document.createElement('div') })
    controller.unsubscribe = jest.fn()
    controller.renderTopics = jest.fn()
    global.fetch = jest.fn(() => new Promise(resolve => { finishRequest = resolve }))

    const loading = controller.loadTopics()
    controller.onPopupClosed()
    finishRequest({
      ok: true,
      status: 200,
      json: async () => ({ topics: [{ id: 1, name: 'Stale' }] }),
    })
    await loading

    expect(controller.renderTopics).not.toHaveBeenCalled()
    expect(controller.topics).toEqual([])
    delete global.fetch
  })
})
