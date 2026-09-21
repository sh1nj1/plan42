/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentReadTracker from '../comment_read_tracker'

describe('CommentReadTracker', () => {
  let controller
  let request
  let tracker

  beforeEach(() => {
    jest.useFakeTimers()
    request = jest.fn().mockResolvedValue({ ok: true })
    controller = {
      creativeId: '42',
      currentTopicId: null,
      element: document.createElement('div'),
      popupController: { topicsController: { loadTopics: jest.fn() } },
    }
    document.body.appendChild(controller.element)
    tracker = new CommentReadTracker(controller, { request })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    jest.useRealTimers()
  })

  test('owns the rendered All Messages snapshot lifecycle', () => {
    tracker.captureRenderedSnapshot('1,2', '{"1":20,"2":21,"_legacy":19}')

    expect(controller.renderedAllTopicIds).toEqual(['1', '2'])
    expect(controller.renderedAllTopicWatermarks).toEqual({ 1: 20, 2: 21, _legacy: 19 })
    expect(controller.renderedAllIncludesLegacy).toBe(true)

    tracker.resetRenderedSnapshot()

    expect(controller.renderedAllTopicIds).toBeNull()
    expect(controller.renderedAllTopicWatermarks).toBeNull()
    expect(controller.renderedAllIncludesLegacy).toBe(false)
  })

  test('keeps topic IDs while discarding a malformed watermark header', () => {
    tracker.captureRenderedSnapshot('1,2', '{malformed')

    expect(controller.renderedAllTopicIds).toEqual(['1', '2'])
    expect(controller.renderedAllTopicWatermarks).toBeNull()
    expect(controller.renderedAllIncludesLegacy).toBe(false)
  })

  test('flushes the captured snapshot with unload-safe request options', () => {
    controller.renderedAllTopicIds = ['1', '2']
    controller.renderedAllTopicWatermarks = { 1: 20, 2: 21 }
    tracker.markCommentsRead()

    tracker.flushPendingRead({ keepalive: true })

    expect(request).toHaveBeenCalledWith('/comment_read_pointers/update', expect.objectContaining({
      method: 'POST',
      keepalive: true,
      body: JSON.stringify({
        creative_id: '42',
        topic_id: null,
        topic_ids: ['1', '2'],
        topic_watermarks: { 1: 20, 2: 21 },
      }),
    }))
  })
})
