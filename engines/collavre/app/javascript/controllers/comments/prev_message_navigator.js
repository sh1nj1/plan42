// Tracks where the "previous message" button left off.
//
// The button scrolls with `behavior: 'smooth'`, so a rapid second click arrives
// while the list is still mid-animation. Deriving the current position purely
// from geometry at that moment picks the item we just left (it has not reached
// the top yet), which makes the list bounce up and down instead of walking
// backwards. Remembering the last target as an anchor keeps each click stepping
// one message further back, and geometry only takes over once the user scrolls
// on their own.
//
// Kept free of DOM access so it can be unit tested: jsdom has no layout engine,
// so the controller measures the items and passes `{ id, top }` pairs in.

// Sub-pixel scroll offsets (HiDPI, browser rounding) mean an item parked at the
// top is rarely at exactly `viewportTop`.
const TOP_TOLERANCE = 4

export default class PrevMessageNavigator {
  constructor() {
    this.anchorId = null
    this.scrolling = false
  }

  // items: `{ id, top }` in DOM order (oldest first), top relative to viewport.
  // Returns the index to scroll to, or -1 when there is nothing older in the
  // list (the caller then loads older comments).
  resolveTargetIndex(items, viewportTop) {
    if (items.length === 0) return -1

    if (this.anchorId !== null) {
      const anchorIdx = items.findIndex((item) => item.id === this.anchorId)
      if (anchorIdx !== -1) return anchorIdx - 1
    }

    let currentIdx = items.findIndex((item) => item.top >= viewportTop - TOP_TOLERANCE)
    if (currentIdx === -1) currentIdx = items.length - 1

    const isAtTop = Math.abs(items[currentIdx].top - viewportTop) < TOP_TOLERANCE
    return isAtTop ? currentIdx - 1 : currentIdx
  }

  // Called once we start scrolling towards `id`.
  commit(id) {
    this.anchorId = id
    this.scrolling = true
  }

  // Called when the smooth scroll has landed.
  settle() {
    this.scrolling = false
  }

  // Called on every scroll event. Scroll events fired by our own animation must
  // not clear the anchor — only a scroll the user drove themselves.
  handleScroll() {
    if (this.scrolling) return
    this.anchorId = null
  }

  // Called when the list contents are replaced wholesale.
  reset() {
    this.anchorId = null
    this.scrolling = false
  }
}
