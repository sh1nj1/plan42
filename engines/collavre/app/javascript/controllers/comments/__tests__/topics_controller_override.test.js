/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import TopicsController from '../topics_controller'

describe('TopicsController override topic selection', () => {
  let application
  let container
  let controller

  beforeEach(() => {
    container = document.createElement('div')
    container.innerHTML = `
      <div id="topics" data-controller="comments--topics">
        <div data-comments--topics-target="list"></div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--topics', TopicsController)

    return new Promise(resolve => setTimeout(resolve, 0)).then(() => {
      const element = document.getElementById('topics')
      controller = application.getControllerForElementAndIdentifier(element, 'comments--topics')
      controller.serverLastTopicId = '533'
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    application.stop()
    window.history.replaceState({}, '', '/')
  })

  test('returns override topic id before saved topic id', () => {
    controller.setOverrideTopicId('777')

    expect(controller.currentTopicId).toBe('777')
  })

  test('returns url topic id when override is absent', () => {
    window.history.replaceState({}, '', '/creatives/10544?topic_id=888')

    expect(controller.currentTopicId).toBe('888')
  })

  test('returns saved topic id when override and url topic id are absent', () => {
    expect(controller.currentTopicId).toBe('533')
  })

  test('clearOverrideTopicId removes one-shot override', () => {
    controller.setOverrideTopicId('777')
    controller.clearOverrideTopicId()

    expect(controller.currentTopicId).toBe('533')
  })
})
