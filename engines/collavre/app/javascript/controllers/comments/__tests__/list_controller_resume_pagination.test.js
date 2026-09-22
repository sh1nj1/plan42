/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import ListController from '../list_controller'
import PopupController from '../popup_controller'

const comment = (id) => `<div class="comment-item" data-comment-id="${id}" data-topic-id="9"></div>`
const response = (html) => ({ ok: true, headers: { get: () => null }, text: async () => html })
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
const deferred = () => {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return { promise, resolve }
}

describe('comment pagination after returning to the app', () => {
  let controller, popup, list, originalFetch

  beforeEach(() => {
    originalFetch = global.fetch
    const element = document.createElement('div')
    element.style.display = 'flex'
    list = document.createElement('div')
    element.appendChild(list)
    document.body.appendChild(element)
    Object.defineProperty(list, 'scrollHeight', { get: () => list.children.length * 1000 })
    Object.defineProperty(list, 'clientHeight', { value: 100 })

    controller = Object.create(ListController.prototype)
    Object.defineProperties(controller, {
      element: { value: element },
      listTarget: { value: list },
      popupController: { value: null },
      formController: { value: null },
    })
    controller.connect()
    controller.creativeId = '42'
    controller.currentTopicId = '9'
    controller.initialLoadComplete = true
    controller.markCommentsRead = jest.fn()
    controller.scrollToBottom = jest.fn()
    list.innerHTML = comment(20)

    popup = Object.create(PopupController.prototype)
    Object.defineProperties(popup, {
      element: { value: element },
      listController: { value: controller },
    })
    popup._syncWakeLock = jest.fn()
    Object.defineProperty(document, 'hidden', { configurable: true, value: false })
  })

  afterEach(() => {
    controller.disconnect()
    document.body.innerHTML = ''
    delete document.hidden
    global.fetch = originalFetch
  })

  test.each(['handleWindowFocus', 'handleVisibilityChange', 'handleOnline'])(
    '%s allows scrolling to older messages after previously reaching the beginning', async (event) => {
      global.fetch = jest.fn().mockResolvedValueOnce(response(''))
      controller.loadOlderComments()
      await settle()
      expect(controller.allOlderLoaded).toBe(true)

      global.fetch.mockResolvedValueOnce(response(comment(20)))
      popup[event]()
      await settle()

      global.fetch.mockResolvedValueOnce(response(comment(10)))
      list.dispatchEvent(new Event('scroll'))
      await settle()

      expect(global.fetch).toHaveBeenLastCalledWith('/creatives/42/comments?before_id=20&topic_id=9')
      expect(list.querySelector('[data-comment-id="10"]')).not.toBeNull()
      expect(controller.loadingOlder).toBe(false)
      expect(controller.allNewerLoaded).toBe(true)
    },
  )

  test.each(['Older', 'Newer'])('releases an in-flight %s request without letting its late response unlock a newer request', async (direction) => {
    const oldPage = deferred()
    global.fetch = jest.fn().mockReturnValueOnce(oldPage.promise)
    controller.allNewerLoaded = false
    controller[`load${direction}Comments`]()
    expect(controller[`loading${direction}`]).toBe(true)

    global.fetch.mockResolvedValueOnce(response(comment(20)))
    popup.handleWindowFocus()
    await settle()
    expect(controller.loadingOlder).toBe(false)
    expect(controller.loadingNewer).toBe(false)

    const newPage = deferred()
    global.fetch.mockReturnValueOnce(newPage.promise)
    controller.allNewerLoaded = false
    controller[`load${direction}Comments`]()
    oldPage.resolve(response(''))
    await settle()
    expect(controller[`loading${direction}`]).toBe(true)
    expect(controller[`all${direction}Loaded`]).toBe(false)

    newPage.resolve(response(comment(direction === 'Older' ? 10 : 30)))
    await settle()
    expect(controller[`loading${direction}`]).toBe(false)
    expect(list.children).toHaveLength(2)
  })

  test('blocks pagination on the old list while refreshing and ignores superseded refreshes', async () => {
    const first = deferred()
    const second = deferred()
    global.fetch = jest.fn().mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise)
    popup.handleWindowFocus()
    popup.handleVisibilityChange()

    list.dispatchEvent(new Event('scroll'))
    controller.loadOlderComments()
    controller.loadNewerComments()
    expect(global.fetch).toHaveBeenCalledTimes(2)
    expect(controller.initialLoadComplete).toBe(false)

    first.resolve(response(comment(15)))
    await settle()
    expect(controller.loadingOlder).toBe(true)
    expect(list.innerHTML).toBe(comment(20))

    second.resolve(response(comment(30)))
    await settle()
    expect(controller.loadingOlder).toBe(false)
    expect(controller.loadingNewer).toBe(false)
    expect(controller.initialLoadComplete).toBe(true)
    expect(list.innerHTML).toBe(comment(30))
  })

  test('refresh cancels queued previous-message steps and discards their late page', async () => {
    const oldPage = deferred()
    global.fetch = jest.fn().mockReturnValueOnce(oldPage.promise)
    controller.prevMsgNavigator.commit('20', 0)
    const navigation = controller.loadAndNavigateToPreviousMessage('20')
    controller.loadAndNavigateToPreviousMessage('20')
    expect(controller.pendingPreviousMessageNavigation.steps).toBe(2)

    const refresh = deferred()
    global.fetch.mockReturnValueOnce(refresh.promise)
    popup.handleWindowFocus()
    expect(controller.pendingPreviousMessageNavigation).toBeNull()
    expect(controller.loadingOlderPromise).toBeNull()
    expect(await controller.loadOlderComments()).toBe(false)

    oldPage.resolve(response(comment(10)))
    expect(await navigation).toBe(false)
    expect(controller.loadingOlder).toBe(true)
    expect(list.innerHTML).toBe(comment(20))

    refresh.resolve(response(comment(30)))
    await settle()
    expect(controller.loadingOlder).toBe(false)
    expect(list.querySelector('[data-highlighted="true"]')).toBeNull()
    expect(list.innerHTML).toBe(comment(30))
  })

  test('recovers pagination after a failed refresh is retried', async () => {
    global.fetch = jest.fn().mockRejectedValueOnce(new Error('offline'))
    popup.handleWindowFocus()
    await settle()
    expect(list.textContent).toBe('offline')

    global.fetch.mockResolvedValueOnce(response(comment(20)))
    popup.handleOnline()
    await settle()
    global.fetch.mockResolvedValueOnce(response(comment(10)))
    list.dispatchEvent(new Event('scroll'))
    await settle()
    expect(list.children).toHaveLength(2)
  })

  test.each(['selection', 'closed'])('leaves pagination alone when refresh is skipped for %s', (reason) => {
    if (reason === 'selection') controller.selection.add('20')
    else controller.creativeId = null
    global.fetch = jest.fn()
    popup.handleWindowFocus()
    expect(global.fetch).not.toHaveBeenCalled()
    expect(controller.initialLoadComplete).toBe(true)
    expect(controller.loadingOlder).toBe(false)
  })
})
