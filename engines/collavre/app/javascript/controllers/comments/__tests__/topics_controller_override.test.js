/**
 * @jest-environment jsdom
 */

import TopicsController from '../topics_controller'

describe('TopicsController override topic selection', () => {
  let controller

  beforeEach(() => {
    controller = Object.create(TopicsController.prototype)
    controller.serverLastTopicId = '533'
    delete controller.overrideTopicId
    window.history.replaceState({}, '', '/creatives/10544')
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
