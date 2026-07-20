// Tracks where the "previous message" button left off.
//
// The button scrolls with `behavior: 'smooth'`, so a rapid second click arrives
// while the list is still mid-animation. Deriving the current position purely
// from geometry at that moment picks the item we just left (it has not reached
// the top yet), which makes the list bounce up and down instead of walking
// backwards. Remembering the last target as an anchor keeps each click stepping
// one message further back.
//
// The anchor is dropped once the user moves the list themselves, so geometry
// takes over from wherever they landed. Invalidation is driven by input events
// rather than scroll events: a scroll event cannot be attributed to the user
// without guessing how long our own animation runs, and guessing short brings
// the bounce back. Dropping the anchor is always the safe direction — a settled
// list resolves correctly from geometry alone.
//
// Kept free of DOM access so it can be unit tested: jsdom has no layout engine,
// so the controller measures the items and passes `{ id, top }` pairs in.

// Sub-pixel scroll offsets (HiDPI, browser rounding) mean an item parked at the
// top is rarely at exactly `viewportTop`.
const TOP_TOLERANCE = 4

export default class PrevMessageNavigator {
  constructor() {
    this.anchorId = null
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
  }

  // Called when the user interacts with the list (wheel, touch, key, pointer).
  notifyUserInput() {
    this.anchorId = null
  }

  // Called when the list contents are replaced wholesale.
  reset() {
    this.anchorId = null
  }
}
