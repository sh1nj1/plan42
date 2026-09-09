/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

describe('CommentsListController read pointer updates', () => {
  let controller
  let topicsController
  const successfulResponse = () => ({ ok: true, headers: { get: () => null } })

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
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(global.fetch).toHaveBeenCalledWith('/comment_read_pointers/update', expect.objectContaining({ method: 'POST' }))
    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
    expect(topicsController.loadTopics).toHaveBeenCalledTimes(1)
  })

  test('sends the selected topic to the read pointer endpoint', async () => {
    controller.currentTopicId = '9'
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: '9' })
  })

  test('keeps the rendered All Messages topic snapshot in a read update', async () => {
    controller.renderedAllTopicIds = ['1', '2']
    controller.renderedAllTopicWatermarks = { 1: 20, 2: 21 }
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1', '2'], topic_watermarks: { 1: 20, 2: 21 }
    })
  })

  test('extends the All Messages read bound when pagination renders an older topic', async () => {
    controller.currentTopicId = null
    controller.renderedAllTopicIds = ['1']
    controller.renderedAllTopicWatermarks = { 1: 20 }
    controller.loadingOlder = false
    controller.allOlderLoaded = false
    controller.listTarget = document.createElement('div')
    controller.listTarget.innerHTML = '<div class="comment-item" data-comment-id="20" data-topic-id="1"></div>'
    Object.defineProperty(controller.listTarget, 'scrollHeight', { value: 100 })
    controller.listTarget.scrollTop = 0
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      headers: { get: () => null },
      text: async () => '<div class="comment-item" data-comment-id="10" data-topic-id="2"></div>',
    })

    const renderedSnapshots = []
    controller.element.addEventListener('comments--list:rendered-all-topics', (event) => renderedSnapshots.push(event.detail))

    controller.loadOlderComments()
    await Promise.resolve()
    await Promise.resolve()
    await jest.advanceTimersByTimeAsync(2000)

    expect(controller.renderedAllTopicIds).toEqual(['1', '2'])
    expect(controller.renderedAllTopicWatermarks).toEqual({ 1: 20, 2: 10 })
    expect(renderedSnapshots).toEqual([{ creativeId: '42', topicIds: ['1', '2'], includesLegacy: undefined }])
    expect(JSON.parse(global.fetch.mock.calls[1][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1', '2'], topic_watermarks: { 1: 20, 2: 10 }
    })
  })

  test('uses History change set IDs when the read-only topic has no comment rows', () => {
    controller.listTarget = document.createElement('div')
    controller.listTarget.innerHTML = `
      <article class="creative-history-item" data-change-set-id="7"></article>
      <article class="creative-history-item" data-change-set-id="9"></article>
    `

    expect(controller.getMinId()).toBe(7)
    expect(controller.getMaxId()).toBe(9)
  })

  test('extends the All Messages read bound when pagination renders a legacy comment', async () => {
    controller.currentTopicId = null
    controller.renderedAllTopicIds = ['1']
    controller.renderedAllTopicWatermarks = { 1: 20 }
    controller.renderedAllIncludesLegacy = false
    controller.loadingOlder = false
    controller.allOlderLoaded = false
    controller.listTarget = document.createElement('div')
    controller.listTarget.innerHTML = '<div class="comment-item" data-comment-id="20" data-topic-id="1"></div>'
    Object.defineProperty(controller.listTarget, 'scrollHeight', { value: 100 })
    controller.listTarget.scrollTop = 0
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      headers: { get: () => null },
      text: async () => '<div class="comment-item" data-comment-id="10" data-topic-id=""></div>',
    })

    const renderedSnapshots = []
    controller.element.addEventListener('comments--list:rendered-all-topics', (event) => renderedSnapshots.push(event.detail))

    controller.loadOlderComments()
    await Promise.resolve()
    await Promise.resolve()
    await jest.advanceTimersByTimeAsync(2000)

    expect(controller.renderedAllTopicWatermarks).toEqual({ 1: 20, _legacy: 10 })
    expect(renderedSnapshots).toEqual([{ creativeId: '42', topicIds: ['1'], includesLegacy: true }])
    expect(JSON.parse(global.fetch.mock.calls[1][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1'], topic_watermarks: { 1: 20, _legacy: 10 }
    })
  })

  test('extends the All Messages read bound for a locally appended comment', async () => {
    controller.currentTopicId = null
    controller.renderedAllTopicIds = ['1']
    controller.renderedAllTopicWatermarks = { 1: 20 }
    controller.listTarget = document.createElement('div')
    controller.listTarget.innerHTML = '<div class="comment-item" data-comment-id="21" data-topic-id="1"></div>'
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())

    controller.recordRenderedAllTopicWatermarks(controller.listTarget.firstElementChild)
    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1'], topic_watermarks: { 1: 21 }
    })
  })

  test('extends the All Messages read bound when a local append introduces a topic', async () => {
    controller.currentTopicId = null
    controller.renderedAllTopicIds = ['1']
    controller.renderedAllTopicWatermarks = { 1: 20 }
    controller.listTarget = document.createElement('div')
    controller.listTarget.innerHTML = '<div class="comment-item" data-comment-id="21" data-topic-id="2"></div>'
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())

    const addedTopic = controller.recordRenderedAllTopicWatermarks(
      controller.listTarget.firstElementChild,
      { includeNewTopics: true },
    )
    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(addedTopic).toBe(true)
    expect(controller.renderedAllTopicIds).toEqual(['1', '2'])
    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1', '2'], topic_watermarks: { 1: 20, 2: 21 }
    })
  })

  test('discards an older pagination response after switching conversations', async () => {
    controller.currentTopicId = null
    controller.renderedAllTopicIds = ['1']
    controller.renderedAllTopicWatermarks = { 1: 20 }
    controller.loadingOlder = false
    controller.allOlderLoaded = false
    controller._loadCommentsVersion = 4
    controller.listTarget = document.createElement('div')
    controller.listTarget.innerHTML = '<div class="comment-item" data-comment-id="20" data-topic-id="1"></div>'
    Object.defineProperty(controller.listTarget, 'scrollHeight', { value: 100 })
    controller.listTarget.scrollTop = 0
    let resolveResponse
    global.fetch = jest.fn().mockReturnValue(new Promise((resolve) => { resolveResponse = resolve }))

    controller.loadOlderComments()
    controller.creativeId = '43'
    controller.currentTopicId = '9'
    controller._loadCommentsVersion = 5
    resolveResponse({
      ok: true,
      headers: { get: () => null },
      text: async () => '<div class="comment-item" data-comment-id="10" data-topic-id="1"></div>',
    })
    await Promise.resolve()
    await Promise.resolve()
    await jest.advanceTimersByTimeAsync(2000)

    expect(controller.listTarget.querySelector('[data-comment-id="10"]')).toBeNull()
    expect(controller.renderedAllTopicWatermarks).toEqual({ 1: 20 })
    expect(global.fetch).toHaveBeenCalledTimes(1)
  })

  test('does not reload topic unread counts after a failed read pointer update', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false })

    controller.markCommentsRead()
    await jest.advanceTimersByTimeAsync(2000)

    expect(topicsController.loadTopics).not.toHaveBeenCalled()
  })

  test('flushes a pending read pointer update before closing the popup', () => {
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())
    controller.resetState = jest.fn()
    controller.listTarget = document.createElement('div')
    controller.markCommentsRead()

    controller.onPopupClosed()

    expect(global.fetch).toHaveBeenCalledWith('/comment_read_pointers/update', expect.objectContaining({ method: 'POST' }))
    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
  })

  test('uses an unload-safe request when disconnecting with a pending read', () => {
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())
    controller.listTarget = document.createElement('div')
    document.body.appendChild(controller.listTarget)
    controller.markCommentsRead()

    controller.disconnect()

    expect(global.fetch).toHaveBeenCalledWith('/comment_read_pointers/update', expect.objectContaining({
      method: 'POST', keepalive: true,
    }))
  })

  test('flushes a pending read pointer update before switching topics', () => {
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())
    controller.resetToLatest = jest.fn()
    controller.markCommentsRead()

    controller.handleTopicChange({ detail: { topicId: '9' } })

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
    expect(controller.currentTopicId).toBe('9')
  })

  test('flushes a pending read pointer update before opening another creative', () => {
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())
    controller.resetState = jest.fn()
    controller.loadInitialComments = jest.fn()
    controller.listTarget = document.createElement('div')
    Object.defineProperty(controller, 'presenceController', { value: null })
    controller.markCommentsRead()

    controller.onPopupOpened({ creativeId: '43', topicId: '9' })

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({ creative_id: '42', topic_id: null })
    expect(controller.creativeId).toBe('43')
  })

  test('flushes a pending All Messages snapshot before applying a search', () => {
    global.fetch = jest.fn().mockResolvedValue(successfulResponse())
    controller.renderedAllTopicIds = ['1', '2']
    controller.renderedAllTopicWatermarks = { 1: 20, 2: 21 }
    controller.resetState = jest.fn()
    controller.loadInitialComments = jest.fn()
    controller.listTarget = document.createElement('div')
    controller.markCommentsRead()

    controller.applySearchQuery('only topic one')

    expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual({
      creative_id: '42', topic_id: null, topic_ids: ['1', '2'], topic_watermarks: { 1: 20, 2: 21 }
    })
    expect(controller.manualSearchQuery).toBe('only topic one')
    expect(controller.loadInitialComments).toHaveBeenCalledTimes(1)
  })
})
