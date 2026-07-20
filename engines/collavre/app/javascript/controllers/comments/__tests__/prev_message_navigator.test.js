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
      nav.commit('1')

      // Second click lands mid-animation: item 1 has not reached the top yet, so
      // geometry alone would send us back down to item 1. The anchor must win.
      expect(nav.resolveTargetIndex(items(-150, -50, 150, 350), VIEWPORT_TOP)).toBe(0)
    })

    test('survives older comments being prepended (anchor is id based)', () => {
      nav.commit('c5')
      const prepended = [
        { id: 'c3', top: -100 },
        { id: 'c4', top: 0 },
        { id: 'c5', top: 400 },
      ]
      expect(nav.resolveTargetIndex(prepended, VIEWPORT_TOP)).toBe(1)
    })

    test('falls back to geometry when the anchored comment is gone', () => {
      nav.commit('deleted-comment')
      expect(nav.resolveTargetIndex(items(-200, -100, 100, 300), VIEWPORT_TOP)).toBe(1)
    })

    test('returns -1 when the anchor is already the oldest item', () => {
      nav.commit('0')
      expect(nav.resolveTargetIndex(items(100, 300), VIEWPORT_TOP)).toBe(-1)
    })
  })

  describe('anchor invalidation', () => {
    test('ignores the scroll events produced by our own animation', () => {
      nav.commit('1')
      nav.handleScroll()
      expect(nav.anchorId).toBe('1')
    })

    test('drops the anchor once the user scrolls after the animation settles', () => {
      nav.commit('1')
      nav.settle()
      nav.handleScroll()
      expect(nav.anchorId).toBeNull()
    })

    test('reset clears both the anchor and the in-flight flag', () => {
      nav.commit('1')
      nav.reset()
      expect(nav.anchorId).toBeNull()
      nav.handleScroll()
      expect(nav.anchorId).toBeNull()
    })

    test('after a user scroll, geometry drives the next click again', () => {
      nav.commit('1')
      nav.settle()
      nav.handleScroll()
      expect(nav.resolveTargetIndex(items(-200, -100, 130, 330), VIEWPORT_TOP)).toBe(2)
    })
  })
})
