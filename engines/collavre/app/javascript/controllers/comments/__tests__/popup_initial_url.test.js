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
    window.innerWidth = previousWidth
    window.history.replaceState({}, '', previousUrl)
  })

  test.each([390, 767])('loads topics and comments with a pre-rendered inbox button at %ipx', async width => {
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
  })
})
