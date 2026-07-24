/**
 * @jest-environment jsdom
 */

/**
 * Covers the previous-message wiring in list_controller: anchor lifecycle across
 * connect/disconnect, list reloads, and the scroll action itself.
 *
 * jsdom has no layout engine, so item geometry is stubbed. `scrollTo` records
 * the request without moving `scrollTop` — that models the smooth-scroll
 * animation still being in flight, which is the state the original bug needed.
 */

import { jest } from '@jest/globals'
import ListController from '../list_controller'

const ITEM_HEIGHT = 100

function buildController({ itemCount = 5 } = {}) {
  const state = { scrollTop: 0 }

  const element = document.createElement('div')
  const list = document.createElement('div')
  element.appendChild(list)
  document.body.appendChild(element)

  for (let i = 0; i < itemCount; i++) {
    const item = document.createElement('div')
    item.className = 'comment-item'
    item.dataset.commentId = `c${i}`
    Object.defineProperty(item, 'offsetTop', { get: () => i * ITEM_HEIGHT })
    item.getBoundingClientRect = () => ({ top: i * ITEM_HEIGHT - state.scrollTop })
    list.appendChild(item)
  }

  list.getBoundingClientRect = () => ({ top: 0 })
  Object.defineProperty(list, 'offsetTop', { get: () => 0 })
  list.scrollTo = jest.fn()

  // Stand the controller up without a Stimulus application: `element` is a
  // getter on Controller.prototype, so it has to be shadowed rather than set.
  const controller = Object.create(ListController.prototype)
  Object.defineProperty(controller, 'element', { value: element })
  Object.defineProperty(controller, 'listTarget', { value: list })
  controller.connect()

  return {
    controller,
    list,
    element,
    // Apply the last requested scroll, i.e. let the smooth animation finish.
    settle() {
      const call = list.scrollTo.mock.calls.at(-1)
      if (call) state.scrollTop = call[0].top
    },
    // Move the list without going through the button, as a user gesture would.
    scrollTo(top) {
      state.scrollTop = top
    },
    lastScrollTop() {
      return list.scrollTo.mock.calls.at(-1)?.[0].top
    },
  }
}

describe('list_controller previous-message navigation', () => {
  afterEach(() => {
    document.body.innerHTML = ''
  })

  test('connect installs a navigator', () => {
    const { controller } = buildController()
    expect(controller.prevMsgNavigator).toBeTruthy()
  })

  test('walks backwards one message per click when settled', () => {
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT) // parked on the last item

    h.controller.scrollToPreviousMessage()
    expect(h.lastScrollTop()).toBe(3 * ITEM_HEIGHT)
    h.settle()

    h.controller.scrollToPreviousMessage()
    expect(h.lastScrollTop()).toBe(2 * ITEM_HEIGHT)
  })

  test('keeps stepping back when clicked mid-animation', () => {
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT)

    // Three clicks with no settle between them: the list never reaches the
    // requested offset, which is exactly when the old geometry-only code
    // bounced back to the item it had just left.
    h.controller.scrollToPreviousMessage()
    expect(h.lastScrollTop()).toBe(3 * ITEM_HEIGHT)
    h.controller.scrollToPreviousMessage()
    expect(h.lastScrollTop()).toBe(2 * ITEM_HEIGHT)
    h.controller.scrollToPreviousMessage()
    expect(h.lastScrollTop()).toBe(1 * ITEM_HEIGHT)
  })

  test('releases stick-to-bottom so incoming comments do not yank the view', () => {
    const h = buildController()
    h.controller.stickToBottom = true
    h.scrollTo(4 * ITEM_HEIGHT)

    h.controller.scrollToPreviousMessage()

    expect(h.controller.stickToBottom).toBe(false)
  })

  test('does nothing when the list is empty', () => {
    const h = buildController({ itemCount: 0 })

    h.controller.scrollToPreviousMessage()

    expect(h.list.scrollTo).not.toHaveBeenCalled()
  })

  test('loads older comments once past the oldest message', () => {
    const h = buildController()
    h.controller.allOlderLoaded = false
    h.controller.loadOlderComments = jest.fn()

    h.controller.scrollToPreviousMessage() // lands on the oldest item
    h.settle()
    h.controller.scrollToPreviousMessage() // nothing older in the DOM

    expect(h.controller.loadOlderComments).toHaveBeenCalled()
  })

  test('stops at the oldest message when everything is already loaded', () => {
    const h = buildController()
    h.controller.allOlderLoaded = true
    h.controller.loadOlderComments = jest.fn()

    h.controller.scrollToPreviousMessage()
    h.settle()
    const before = h.list.scrollTo.mock.calls.length
    h.controller.scrollToPreviousMessage()

    expect(h.controller.loadOlderComments).not.toHaveBeenCalled()
    expect(h.list.scrollTo.mock.calls.length).toBe(before)
  })

  describe.each(['wheel', 'touchstart', 'keydown', 'pointerdown'])(
    'user input via %s',
    (eventName) => {
      test('drops the anchor so the next click resolves from where the user landed', () => {
        const h = buildController()
        h.scrollTo(4 * ITEM_HEIGHT)

        h.controller.scrollToPreviousMessage() // anchor = c3
        h.settle()

        // User scrolls back down to the bottom themselves.
        h.list.dispatchEvent(new Event(eventName))
        h.scrollTo(4 * ITEM_HEIGHT)

        h.controller.scrollToPreviousMessage()

        // Resolved from geometry (c4 at top -> c3), not from the stale anchor.
        expect(h.lastScrollTop()).toBe(3 * ITEM_HEIGHT)
      })
    }
  )

  test('a programmatic jump to the bottom drops the anchor', () => {
    // form_controller (after sending) and the fullscreen handlers call
    // scrollToBottom() with no user gesture. A small jump can leave the anchor
    // inside the corridor, where geometry cannot tell it from our own in-flight
    // scroll, so the next click would step off the stale anchor (c3 -> c2)
    // instead of resolving from where the list actually is (c4 -> c3).
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT)

    h.controller.scrollToPreviousMessage() // anchor = c3, in flight
    expect(h.controller.prevMsgNavigator.anchorId).toBe('c3')

    h.controller.scrollToBottom()
    expect(h.controller.prevMsgNavigator.anchorId).toBeNull()

    h.controller.scrollToPreviousMessage()
    expect(h.lastScrollTop()).toBe(3 * ITEM_HEIGHT) // c3 from geometry, not c2
  })

  test('a permalink highlight jump drops the anchor', () => {
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT)

    h.controller.scrollToPreviousMessage() // anchor = c3
    expect(h.controller.prevMsgNavigator.anchorId).toBe('c3')

    // highlightComment looks the target up by DOM id and scrolls it into view
    // (jsdom has no scrollIntoView, so stub it).
    const target = h.list.querySelector('[data-comment-id="c1"]')
    target.id = 'comment_c1'
    target.scrollIntoView = () => {}
    h.controller.highlightComment('c1')

    expect(h.controller.prevMsgNavigator.anchorId).toBeNull()
  })

  test('notifyProgrammaticScroll seam drops the anchor for sibling controllers', () => {
    // The review-quote chip in form_controller scrolls the list on its own and
    // drops the anchor through this public seam, without reaching into the
    // navigator's internals. Exercise the real seam, not a mock of it.
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT)

    h.controller.scrollToPreviousMessage() // anchor = c3
    expect(h.controller.prevMsgNavigator.anchorId).toBe('c3')

    h.controller.notifyProgrammaticScroll()

    expect(h.controller.prevMsgNavigator.anchorId).toBeNull()
  })

  test('disconnect unhooks the user-input listeners', () => {
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT)
    h.controller.scrollToPreviousMessage() // anchor = c3
    h.settle()

    h.controller.disconnect()
    h.list.dispatchEvent(new Event('wheel'))

    // Anchor survived because the listener is gone.
    expect(h.controller.prevMsgNavigator.anchorId).toBe('c3')
  })

  test('reloading the list drops the anchor', () => {
    const h = buildController()
    h.scrollTo(4 * ITEM_HEIGHT)
    h.controller.scrollToPreviousMessage()
    expect(h.controller.prevMsgNavigator.anchorId).toBe('c3')

    h.controller.creativeId = '1'
    h.controller.fetchComments = jest.fn(() => new Promise(() => {}))
    h.controller.loadInitialComments()

    expect(h.controller.prevMsgNavigator.anchorId).toBeNull()
  })
})
