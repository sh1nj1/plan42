/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

// setTopicPrimaryAgent used to drop the PATCH response on the floor and wait for
// the WebSocket broadcast to render the avatar, and it swallowed failures into
// console.error. These tests pin both: the avatar renders from the response with
// no broadcast at all, and failures reach the user.
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({
  confirmDialog: jest.fn(),
  alertDialog: jest.fn(),
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default
const { alertDialog } = await import('../../../lib/utils/dialog')

const AGENT = {
  id: 4,
  name: 'GitHub PR Analyzer',
  avatar_url: '/avatar.png',
  default_avatar: false,
  initial: 'G',
}

describe('TopicsController#setTopicPrimaryAgent', () => {
  let application
  let container
  let controller

  beforeEach(() => {
    container = document.createElement('div')
    container.innerHTML = `
      <div id="topics" data-controller="comments--topics"
           data-topic-set-agent-error="에이전트를 지정할 수 없습니다.">
        <div data-comments--topics-target="list"></div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--topics', TopicsController)

    const meta = document.createElement('meta')
    meta.name = 'csrf-token'
    meta.content = 'test-csrf'
    document.head.appendChild(meta)

    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
      const element = document.getElementById('topics')
      controller = application.getControllerForElementAndIdentifier(element, 'comments--topics')
      controller.creativeIdValue = '42'
      controller.loadTopics = jest.fn()
      controller.topics = [{ id: 1, name: 'Main' }]
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
  })

  test('renders the agent avatar from the PATCH response without any broadcast', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ success: true, topic: { id: 1, name: 'Main', primary_agent: AGENT } }),
    })

    await controller.setTopicPrimaryAgent('1', AGENT)

    const avatar = controller.listTarget.querySelector('.topic-agent-avatar')
    expect(avatar).not.toBeNull()
    expect(avatar.getAttribute('src')).toBe('/avatar.png')
  })

  test('surfaces the server error when the agent is rejected (422)', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      json: async () => ({ error: 'Selected user is not an AI agent' }),
    })

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(alertDialog).toHaveBeenCalledWith('Selected user is not an AI agent')
    expect(controller.listTarget.querySelector('.topic-agent-avatar')).toBeNull()
  })

  // The fallback path has no server-supplied (already localized) error to show,
  // so it must use the localized string handed down by the ERB partial rather
  // than an English literal.
  test('surfaces the localized fallback when the response body is not JSON', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      json: async () => { throw new SyntaxError('Unexpected token <') },
    })

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(alertDialog).toHaveBeenCalledWith('에이전트를 지정할 수 없습니다.')
  })

  test('surfaces the localized fallback when the request itself fails', async () => {
    global.fetch = jest.fn().mockRejectedValue(new TypeError('Failed to fetch'))

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(alertDialog).toHaveBeenCalledWith('에이전트를 지정할 수 없습니다.')
  })

  test('falls back to English when the partial supplied no localized string', async () => {
    delete document.getElementById('topics').dataset.topicSetAgentError
    global.fetch = jest.fn().mockRejectedValue(new TypeError('Failed to fetch'))

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(alertDialog).toHaveBeenCalledWith('Unable to assign the agent to this topic.')
  })
})
