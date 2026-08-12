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
    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
    expect(topicsController.loadTopics).toHaveBeenCalledTimes(1)
  })

  test('sends the selected topic to the read pointer endpoint', async () => {
    controller.currentTopicId = '9'
    global.fetch = jest.fn().mockResolvedValue({ ok: true })

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: '9' })
  })

  test('keeps the rendered All Messages topic snapshot in a read update', async () => {
    controller.renderedAllTopicIds = ['1', '2']
    controller.renderedAllTopicWatermarks = { 1: 20, 2: 21 }
    global.fetch = jest.fn().mockResolvedValue({ ok: true })

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1', '2'], topic_watermarks: { 1: 20, 2: 21 }
    })
  })

  test('does not reload topic unread counts after a failed read pointer update', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false })

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(topicsController.loadTopics).not.toHaveBeenCalled()
  })

  test('flushes a pending read pointer update before closing the popup', () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true })
    controller.resetState = jest.fn()
    controller.listTarget = document.createElement('div')
    controller.markCommentsRead()

    controller.onPopupClosed()

    expect(global.fetch).toHaveBeenCalledWith('/comment_read_pointers/update', expect.objectContaining({ method: 'POST' }))
    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
  })

  test('flushes a pending read pointer update before switching topics', () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true })
    controller.resetToLatest = jest.fn()
    controller.markCommentsRead()

    controller.handleTopicChange({ detail: { topicId: '9' } })

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
    expect(controller.currentTopicId).toBe('9')
  })

  test('flushes a pending read pointer update before opening another creative', () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true })
    controller.resetState = jest.fn()
    controller.loadInitialComments = jest.fn()
    controller.listTarget = document.createElement('div')
    Object.defineProperty(controller, 'presenceController', { value: null })
    controller.markCommentsRead()

    controller.onPopupOpened({ creativeId: '43', topicId: '9' })

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
    expect(controller.creativeId).toBe('43')
  })
})
