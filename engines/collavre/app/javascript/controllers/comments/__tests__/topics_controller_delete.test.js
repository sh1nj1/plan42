/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

// deleteTopic awaits confirmDialog. The native click dispatch completes during
// that await, which resets event.currentTarget to null (DOM spec). Mock the
// dialog so the test controls when it resolves and can null currentTarget in
// between — reproducing the regression where the topic id was read after await.
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({
  confirmDialog: jest.fn(),
  alertDialog: jest.fn(),
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default
const { confirmDialog } = await import('../../../lib/utils/dialog')

describe('TopicsController#deleteTopic', () => {
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

    const meta = document.createElement('meta')
    meta.name = 'csrf-token'
    meta.content = 'test-csrf'
    document.head.appendChild(meta)

    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
      const element = document.getElementById('topics')
      controller = application.getControllerForElementAndIdentifier(element, 'comments--topics')
      controller.creativeIdValue = '42'
      controller.loadTopics = jest.fn()
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
  })

  test('issues DELETE with the topic id even when currentTarget is nulled after the await', async () => {
    const fetchMock = jest.fn().mockResolvedValue({ ok: true })
    global.fetch = fetchMock

    // Simulate the event whose currentTarget is reset to null once the click
    // dispatch finishes (which happens while confirmDialog is awaited).
    const button = document.createElement('button')
    button.dataset.id = '99'
    const event = { stopPropagation: jest.fn(), currentTarget: button }

    confirmDialog.mockImplementation(() => {
      event.currentTarget = null // dispatch completed -> currentTarget reset
      return Promise.resolve(true)
    })

    await controller.deleteTopic(event)

    expect(fetchMock).toHaveBeenCalledWith(
      '/creatives/42/topics/99',
      expect.objectContaining({ method: 'DELETE' })
    )
  })

  test('does not issue DELETE when the user cancels the confirm dialog', async () => {
    const fetchMock = jest.fn()
    global.fetch = fetchMock

    const button = document.createElement('button')
    button.dataset.id = '99'
    const event = { stopPropagation: jest.fn(), currentTarget: button }

    confirmDialog.mockResolvedValue(false)

    await controller.deleteTopic(event)

    expect(fetchMock).not.toHaveBeenCalled()
  })
})
