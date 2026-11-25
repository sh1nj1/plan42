/** @jest-environment jsdom */

import { Application, Controller } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import PopupController from '../popup_controller'

describe('initial mobile inbox URL', () => {
  let application
  let previousWidth
  let previousUrl
  let topicsOpened
  let listOpened

  beforeEach(() => {
    previousWidth = window.innerWidth
    previousUrl = window.location.href
    window.localStorage.clear()
    topicsOpened = jest.fn()
    listOpened = jest.fn()
  })

  afterEach(async () => {
    document.body.innerHTML = ''
    await Promise.resolve()
    application.stop()
    jest.restoreAllMocks()
    window.innerWidth = previousWidth
    window.history.replaceState({}, '', previousUrl)
  })

  async function connectPopup(width) {
    window.innerWidth = width
    window.history.replaceState({}, '', '/creatives?id=123&open_comments=true&topic_id=456&locale=ko')
    document.body.innerHTML = `
      <button name="show-comments-btn" data-creative-id="123" data-can-comment="true"></button>
      <div id="comments-popup" data-controller="comments--popup comments--list comments--topics" data-docked="true" style="display:none">
        <h3 data-comments--popup-target="title"></h3>
        <div data-comments--popup-target="list">로딩 중...</div>
      </div>
    `
    class ListController extends Controller {
      onPopupOpened(options) { listOpened(options) }
    }
    class TopicsController extends Controller {
      clearOverrideTopicId() {}
      async onPopupOpened(options) { topicsOpened(options) }
    }
    application = Application.start()
    application.register('comments--popup', PopupController)
    application.register('comments--list', ListController)
    application.register('comments--topics', TopicsController)
    await new Promise(resolve => setTimeout(resolve, 0))
  }

  test.each([390, 767])('loads topics and comments with a pre-rendered inbox button at %ipx', async width => {
    await connectPopup(width)
    await new Promise(resolve => requestAnimationFrame(resolve))
    await Promise.resolve()

    const popup = document.getElementById('comments-popup')
    const list = application.getControllerForElementAndIdentifier(popup, 'comments--list')
    expect(topicsOpened).toHaveBeenCalledTimes(1)
    expect(topicsOpened).toHaveBeenCalledWith({ creativeId: '123' })
    expect(listOpened).toHaveBeenCalledTimes(1)
    expect(listOpened).toHaveBeenCalledWith(expect.objectContaining({ creativeId: '123' }))
    expect(list.creativeId).toBe('123')
    expect(list.suppressTopicChangeLoad).toBe(false)
    expect(popup.style.display).toBe('flex')
    const controller = application.getControllerForElementAndIdentifier(popup, 'comments--popup')
    expect(controller.openFromUrlFrame).toBeNull()
  })

  test.each([true, false])('does not open a removed popup (disconnect delivered: %s)', async disconnectDelivered => {
    let pendingFrame
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      pendingFrame = callback
      return 0
    })
    const cancelFrame = jest.spyOn(window, 'cancelAnimationFrame')
    await connectPopup(390)
    const popup = document.getElementById('comments-popup')
    const controller = application.getControllerForElementAndIdentifier(popup, 'comments--popup')
    const open = jest.spyOn(controller, 'open')
    const openFromUrl = jest.spyOn(controller, 'openFromUrl')

    popup.remove()
    if (disconnectDelivered) {
      await Promise.resolve()
      expect(cancelFrame).toHaveBeenCalledWith(0)
      expect(controller.openFromUrlFrame).toBeNull()
    }
    // Also guard against a callback delivered before Stimulus observes removal.
    pendingFrame()
    await Promise.resolve()

    expect(openFromUrl).not.toHaveBeenCalled()
    expect(open).not.toHaveBeenCalled()
    expect(topicsOpened).not.toHaveBeenCalled()
    expect(listOpened).not.toHaveBeenCalled()
    expect(controller.openFromUrlObserver).toBeFalsy()
    expect(controller.openFromUrlFrame).toBeNull()
  })
})
