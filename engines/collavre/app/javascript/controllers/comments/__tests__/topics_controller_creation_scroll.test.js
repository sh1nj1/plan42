/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const createTopicWithComments = jest.fn()

jest.unstable_mockModule('../../../lib/api/topics', () => ({
  fetchNextTopicName: jest.fn(),
  createTopicWithComments,
  saveLastTopic: jest.fn(),
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default

describe('TopicsController user-created topic scrolling', () => {
  let application
  let controller

  beforeEach(async () => {
    document.head.innerHTML = '<meta name="csrf-token" content="test-csrf">'
    document.body.innerHTML = `
      <div id="topics" data-controller="comments--topics">
        <div data-comments--topics-target="list"></div>
      </div>
    `

    application = Application.start()
    application.register('comments--topics', TopicsController)
    await new Promise(resolve => setTimeout(resolve, 0))

    controller = application.getControllerForElementAndIdentifier(
      document.getElementById('topics'), 'comments--topics'
    )
    controller.creativeIdValue = '42'
    controller._topicScrollInterrupted = true
    controller.debounceSaveLastTopic = jest.fn()
    controller.flushSaveLastTopic = jest.fn().mockResolvedValue()
    controller.loadTopics = jest.fn(async () => {
      expect(controller._topicScrollInterrupted).toBe(false)
    })
    controller.dispatch = jest.fn()
  })

  afterEach(() => {
    application.stop()
    document.head.innerHTML = ''
    document.body.innerHTML = ''
    jest.clearAllMocks()
    delete global.fetch
  })

  test('allows the new topic to scroll into view after name entry', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ id: 9, name: 'New topic' }),
    })

    await controller.createTopic('New topic')

    expect(controller.loadTopics).toHaveBeenCalledTimes(1)
  })

  test('allows the new topic to scroll into view after moving comments', async () => {
    createTopicWithComments.mockResolvedValue({
      ok: true,
      topic: { id: 10, name: 'Moved comments' },
    })

    await controller.createTopicAndMoveComments(['comment-1'], 'Moved comments')

    expect(controller.loadTopics).toHaveBeenCalledTimes(1)
  })

  test('allows the new topic to scroll into view after an agent drop', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ id: 11, name: 'Talk to Reviewer' }),
    })

    await controller.createTopicWithAgent({ id: 5, name: 'Reviewer' })

    expect(controller.loadTopics).toHaveBeenCalledTimes(1)
  })
})
