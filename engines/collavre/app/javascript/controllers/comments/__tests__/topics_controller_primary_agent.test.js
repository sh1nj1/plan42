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
const { alertDialog, confirmDialog } = await import('../../../lib/utils/dialog')

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
           data-topic-set-agent-error="에이전트를 지정할 수 없습니다."
           data-topic-clear-agent-confirm="%{name} 할당을 해제할까요?">
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

  // A successful response with no topic payload must not throw; the broadcast
  // remains the fallback path in that case.
  test('is a no-op when a successful response carries no topic', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ success: true }),
    })

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(alertDialog).not.toHaveBeenCalled()
    expect(controller.listTarget.querySelector('.topic-agent-avatar')).toBeNull()
  })

  test('does not issue a request when the controller has no creative', async () => {
    controller.creativeIdValue = ''
    global.fetch = jest.fn()

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(global.fetch).not.toHaveBeenCalled()
    expect(alertDialog).not.toHaveBeenCalled()
  })

  test('falls back to English when the partial supplied no localized string', async () => {
    delete document.getElementById('topics').dataset.topicSetAgentError
    global.fetch = jest.fn().mockRejectedValue(new TypeError('Failed to fetch'))

    await controller.setTopicPrimaryAgent('1', AGENT)

    expect(alertDialog).toHaveBeenCalledWith('Unable to assign the agent to this topic.')
  })

  // Releasing the assignment is what keeps a topic primary agent from being a
  // one-way door: the pin silences every other agent's ambient routing, so the
  // avatar has to be able to come back off.
  describe('release', () => {
    const clearEvent = (topicId) => ({
      preventDefault: jest.fn(),
      stopPropagation: jest.fn(),
      currentTarget: { dataset: { id: topicId } },
    })

    beforeEach(() => {
      controller.topics = [{ id: 1, name: 'Main', primary_agent: AGENT }]
    })

    test('renders the assigned avatar as a release control for managers', () => {
      controller.renderTopics(controller.topics, true, true)

      const wrapper = controller.listTarget.querySelector('.topic-agent-avatar-wrapper')
      expect(wrapper.classList.contains('topic-agent-avatar-releasable')).toBe(true)
      expect(wrapper.dataset.action).toContain('comments--topics#clearTopicPrimaryAgent')
      expect(wrapper.dataset.id).toBe('1')
    })

    test('renders a plain avatar for users who cannot manage topics', () => {
      controller.renderTopics(controller.topics, false, false)

      const wrapper = controller.listTarget.querySelector('.topic-agent-avatar-wrapper')
      expect(wrapper.classList.contains('topic-agent-avatar-releasable')).toBe(false)
      expect(wrapper.dataset.action).toBeUndefined()
    })

    test('PATCHes a null agent_id and drops the avatar once confirmed', async () => {
      confirmDialog.mockResolvedValue(true)
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ success: true, topic: { id: 1, name: 'Main', primary_agent: null } }),
      })

      await controller.clearTopicPrimaryAgent(clearEvent('1'))

      expect(confirmDialog).toHaveBeenCalledWith('GitHub PR Analyzer 할당을 해제할까요?')
      expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ agent_id: null })
      expect(controller.listTarget.querySelector('.topic-agent-avatar')).toBeNull()
    })

    test('does nothing when the confirmation is declined', async () => {
      confirmDialog.mockResolvedValue(false)
      global.fetch = jest.fn()

      await controller.clearTopicPrimaryAgent(clearEvent('1'))

      expect(global.fetch).not.toHaveBeenCalled()
    })

    // The avatar sits inside the topic tag, whose own click handler selects the
    // topic. Releasing must not double as a selection.
    test('stops the click from reaching the topic tag', async () => {
      confirmDialog.mockResolvedValue(false)
      const event = clearEvent('1')

      await controller.clearTopicPrimaryAgent(event)

      expect(event.stopPropagation).toHaveBeenCalled()
    })
  })
})
