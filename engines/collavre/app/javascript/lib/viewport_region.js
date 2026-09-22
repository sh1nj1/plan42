// The region a fixed-position popup has to stay inside: the *visual* viewport,
// not window.innerWidth/innerHeight.
//
// On a phone those two disagree exactly when it matters. The on-screen keyboard
// shrinks the visual viewport while innerHeight keeps counting the strip the
// keyboard covers, so a menu placed against innerHeight lands behind the
// keyboard — and comments--presence lifts the chat sheet clear of the keyboard
// on that same resize, moving the anchor out from under any menu already open.
// Desktop has no such split, which is why the same menu looks right there.
//
// offsetLeft/offsetTop put the region back into client coordinates, the ones
// getBoundingClientRect reports and position:fixed resolves against.
export default function visualViewportRect() {
  const viewport = window.visualViewport
  const left = viewport?.offsetLeft || 0
  const top = viewport?.offsetTop || 0
  const width = viewport?.width || window.innerWidth
  const height = viewport?.height || window.innerHeight
  return { left, top, right: left + width, bottom: top + height, width, height }
}
