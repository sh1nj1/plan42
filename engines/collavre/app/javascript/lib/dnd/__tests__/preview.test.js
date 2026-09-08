import { horizontalHit, previewDrop } from '../preview.js'

test('horizontal hit uses the midpoint and preview cleanup removes only its class', () => {
  const el = document.createElement('span')
  el.getBoundingClientRect = () => ({ left: 10, width: 20 })
  expect(horizontalHit({ el, event: { clientX: 19 } })).toBe('left')
  expect(horizontalHit({ el, event: { clientX: 20 } })).toBe('right')
  el.classList.add('topic-tag')
  const cleanup = previewDrop({ el, hit: 'left' })
  expect(el.classList.contains('dnd-over-left')).toBe(true)
  cleanup()
  expect(el.className).toBe('topic-tag')
})
