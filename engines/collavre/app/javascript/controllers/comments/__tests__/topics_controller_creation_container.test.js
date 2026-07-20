/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

// The add-topic button used to be rendered as the last child of the horizontally
// scrolling topic strip, so it drifted off-screen once enough topics existed.
// It now lives outside the strip, left of the topic-list button, and renderTopics
// only toggles it. These tests pin that it stays out of the strip, that the
// permission gate still applies, and that a re-render no longer wipes a name
// being typed.
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({
  confirmDialog: jest.fn(),
  alertDialog: jest.fn(),
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default

const TOPICS = Array.from({ length: 12 }, (_, i) => ({ id: i + 1, name: `topic-${i + 1}` }))

describe('TopicsController create-button placement', () => {
  let application
  let container
  let controller

  beforeEach(() => {
    container = document.createElement('div')
    container.innerHTML = `
      <div id="topics" data-controller="comments--topics">
        <div class="comment-topics-bar">
          <div data-comments--topics-target="list" class="comment-topics-list"
               data-new-topic-placeholder="New Topic"></div>
          <span class="topic-creation-container"
                data-comments--topics-target="creationContainer" hidden></span>
          <button type="button" class="topic-list-btn"></button>
        </div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--topics', TopicsController)

    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
      const element = document.getElementById('topics')
      controller = application.getControllerForElementAndIdentifier(element, 'comments--topics')
      controller.creativeIdValue = '42'
      controller.loadTopics = jest.fn()
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
  })

  test('renders the create button outside the scrolling strip, left of the topic-list button', () => {
    controller.renderTopics(TOPICS, true, true)

    expect(controller.listTarget.querySelector('.add-topic-btn')).toBeNull()

    const button = document.querySelector('.add-topic-btn')
    expect(button).not.toBeNull()

    const creation = button.closest('.topic-creation-container')
    expect(creation.hidden).toBe(false)
    expect(creation.previousElementSibling).toBe(controller.listTarget)
    expect(creation.nextElementSibling.classList.contains('topic-list-btn')).toBe(true)
  })

  test('hides and empties the container when the user cannot create topics', () => {
    controller.renderTopics(TOPICS, true, true)
    controller.renderTopics(TOPICS, false, false)

    const creation = controller.creationContainerTarget
    expect(creation.hidden).toBe(true)
    expect(creation.innerHTML).toBe('')
    expect(document.querySelector('.add-topic-btn')).toBeNull()
  })

  test('re-shows the button when permission is regained', () => {
    controller.renderTopics(TOPICS, false, false)
    controller.renderTopics(TOPICS, true, true)

    expect(controller.creationContainerTarget.hidden).toBe(false)
    expect(document.querySelector('.add-topic-btn')).not.toBeNull()
  })

  // A topic broadcast used to re-render the whole strip and destroy the open input.
  test('preserves an in-progress topic name across a re-render', () => {
    controller.renderTopics(TOPICS, true, true)
    controller.showInput({ preventDefault() {} })

    const input = controller.creationContainerTarget.querySelector('.topic-input')
    input.value = 'half-typed'

    controller.renderTopics([...TOPICS, { id: 99, name: 'from-broadcast' }], true, true)

    expect(controller.creationContainerTarget.querySelector('.topic-input')).toBe(input)
    expect(input.value).toBe('half-typed')
  })

  // createTopic keeps `creating` set across its loadTopics() await, so the
  // re-render it triggers must not mistake the submitted input for live typing.
  test('restores the add button after a successful creation', async () => {
    controller.renderTopics(TOPICS, true, true)
    controller.showInput({ preventDefault() {} })

    const input = controller.creationContainerTarget.querySelector('.topic-input')
    input.value = 'shipped'

    document.head.innerHTML = '<meta name="csrf-token" content="tok">'
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ id: 99, name: 'shipped' }),
    })
    controller.flushSaveLastTopic = jest.fn()
    controller.loadTopics = jest.fn(async () => {
      controller.renderTopics([...TOPICS, { id: 99, name: 'shipped' }], true, true)
    })

    await controller.createTopic('shipped')

    expect(controller.creationContainerTarget.querySelector('.topic-input')).toBeNull()
    expect(document.querySelector('.add-topic-btn')).not.toBeNull()
  })

  // Alt+Left/Right chat navigation switches creatives without blurring the input,
  // so a preserved draft would otherwise be posted to the wrong creative.
  test('drops an in-progress topic name when the creative changes', () => {
    controller.renderTopics(TOPICS, true, true)
    controller.showInput({ preventDefault() {} })
    controller.creationContainerTarget.querySelector('.topic-input').value = 'for-42'

    controller.creativeIdValue = '77'
    controller.renderTopics(TOPICS, true, true)

    expect(controller.creationContainerTarget.querySelector('.topic-input')).toBeNull()
    expect(document.querySelector('.add-topic-btn')).not.toBeNull()
  })

  // The container is static markup, but rendering must not throw if a caller
  // mounts the controller on a stripped-down strip.
  test('no-ops when the container is absent', () => {
    controller.creationContainerTarget.remove()

    expect(() => controller.renderTopics(TOPICS, true, true)).not.toThrow()
    expect(() => controller.showInput({ preventDefault() {} })).not.toThrow()
    expect(controller.listTarget.querySelector('.topic-tag[data-id="12"]')).not.toBeNull()
  })
})
