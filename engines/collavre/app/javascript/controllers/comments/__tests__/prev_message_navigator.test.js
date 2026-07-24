/**
 * @jest-environment jsdom
 */

import PrevMessageNavigator from '../prev_message_navigator'

// Items are ordered oldest -> newest, matching DOM order of `.comment-item`.
// `top` is the item's viewport-relative top, as measured by the controller.
function items(...tops) {
  return tops.map((top, i) => ({ id: String(i), top }))
}

describe('PrevMessageNavigator', () => {
  const VIEWPORT_TOP = 100

  let nav

  beforeEach(() => {
    nav = new PrevMessageNavigator()
  })

  describe('without an anchor (geometry fallback)', () => {
    test('steps to the previous item when the current one is flush with the top', () => {
      // item 2 is exactly at the viewport top -> previous message is item 1
      expect(nav.resolveTargetIndex(items(-200, -100, 100, 300), VIEWPORT_TOP)).toBe(1)
    })

    test('scrolls the partially visible item to the top first', () => {
      // item 2 is cut off above the fold -> bring item 2 fully into view
      expect(nav.resolveTargetIndex(items(-200, -100, 130, 330), VIEWPORT_TOP)).toBe(2)
    })

    test('starts from the last item when everything is scrolled above the fold', () => {
      expect(nav.resolveTargetIndex(items(-300, -200, -100), VIEWPORT_TOP)).toBe(2)
    })

    test('returns -1 at the oldest item so the caller can load older comments', () => {
      expect(nav.resolveTargetIndex(items(100, 300), VIEWPORT_TOP)).toBe(-1)
    })

    test('returns -1 for an empty list', () => {
      expect(nav.resolveTargetIndex([], VIEWPORT_TOP)).toBe(-1)
    })
  })

  describe('with an anchor (rapid clicks)', () => {
    test('keeps stepping backwards while the smooth scroll is still in flight', () => {
      // First click: item 2 is flush with the top, so we head for item 1.
      expect(nav.resolveTargetIndex(items(-200, -100, 100, 300), VIEWPORT_TOP)).toBe(1)
      nav.commit('1', -100)

      // Second click lands mid-animation: item 1 has not reached the top yet, so
      // geometry alone would send us back down to item 1. The anchor must win.
      expect(nav.resolveTargetIndex(items(-150, -50, 150, 350), VIEWPORT_TOP)).toBe(0)
    })

    test('keeps stepping when the first click started from a partially visible item', () => {
      // First click from between messages: item 2 is cut off *below* the top, so
      // we scroll it up into place and the anchor starts below the viewport top.
      expect(nav.resolveTargetIndex(items(-200, -100, 130, 330), VIEWPORT_TOP)).toBe(2)
      nav.commit('2', 130)

      // Second click mid-animation: item 2 is on its way down to the top. The
      // anchor must still win, otherwise we re-target item 2 and stall.
      expect(nav.resolveTargetIndex(items(-215, -115, 115, 315), VIEWPORT_TOP)).toBe(1)
    })

    test('survives older comments being prepended (anchor is id based)', () => {
      // Prepending shifts scrollTop but leaves the anchor where it is on screen,
      // so it is still on its way from -300 up to the viewport top.
      nav.commit('c5', -300)
      const prepended = [
        { id: 'c3', top: -500 },
        { id: 'c4', top: -300 },
        { id: 'c5', top: -100 },
      ]
      expect(nav.resolveTargetIndex(prepended, VIEWPORT_TOP)).toBe(1)
    })

    test('falls back to geometry when the anchored comment is gone', () => {
      nav.commit('deleted-comment', -100)
      expect(nav.resolveTargetIndex(items(-200, -100, 100, 300), VIEWPORT_TOP)).toBe(1)
    })

    test('returns -1 when the anchor is already the oldest item', () => {
      nav.commit('0', -100)
      expect(nav.resolveTargetIndex(items(100, 300), VIEWPORT_TOP)).toBe(-1)
    })

    test('ignores an anchor the list has scrolled away from', () => {
      // A programmatic jump (new message arriving, permalink highlight) moves the
      // list without any user gesture, so nothing drops the anchor. It is now far
      // above where it started, which our own animation can never produce - that
      // only ever walks the anchor down towards the viewport top.
      nav.commit('0', -100)
      expect(nav.resolveTargetIndex(items(-900, -700, 100, 300), VIEWPORT_TOP)).toBe(1)
    })

    test('a stale anchor stops wedging the button at the oldest message', () => {
      // Regression: anchored on the oldest item, every later click returned -1
      // forever once there was nothing more to load, so the button went dead.
      nav.commit('0', -100)
      nav.resolveTargetIndex(items(100, 300), VIEWPORT_TOP)

      // The list is jumped back to the bottom; clicking must resume stepping.
      expect(nav.resolveTargetIndex(items(-900, -700, 100, 300), VIEWPORT_TOP)).toBe(1)
    })
  })

  describe('anchor invalidation', () => {
    test('drops the anchor when the user moves the list', () => {
      nav.commit('1', -100)
      nav.notifyUserInput()
      expect(nav.anchorId).toBeNull()
    })

    test('reset clears the anchor', () => {
      nav.commit('1', -100)
      nav.reset()
      expect(nav.anchorId).toBeNull()
    })

    test('after a user scroll, geometry drives the next click again', () => {
      nav.commit('1', -100)
      nav.notifyUserInput()
      expect(nav.resolveTargetIndex(items(-200, -100, 130, 330), VIEWPORT_TOP)).toBe(2)
    })
  })
})
