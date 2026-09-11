import { jest } from '@jest/globals'
import { attachBundleDragImage, createBundleDragImage } from '../bundle_image'

test.each([[1, 1], [2, 2], [3, 3]])('bundle with %i items shows %i cards and its count', (count, cards) => {
  const image = createBundleDragImage(count, '<img src=x onerror=alert(1)>')
  expect(image.querySelectorAll('.drag-bundle-card')).toHaveLength(cards)
  expect(image.querySelector('img')).toBeNull()
  expect(image.querySelector('.drag-bundle-card--front').textContent).toContain('<img')
  expect(image.querySelector('.drag-bundle-badge')?.textContent).toBe(count > 1 ? String(count) : undefined)
})

test('bundle uses a short preview and a fallback for empty text', () => {
  expect(createBundleDragImage(1, 'a'.repeat(41)).textContent).toBe(`${'a'.repeat(40)}…`)
  expect(createBundleDragImage(1, '').textContent).toBe('—')
})

test('native and touch transfers receive the image before its next-frame cleanup', () => {
  const originalFrame = global.requestAnimationFrame
  const frame = jest.fn(() => 1)
  global.requestAnimationFrame = frame
  try {
    const setDragImage = jest.fn()
    attachBundleDragImage({ dataTransfer: { setDragImage } }, 2, 'Selected')
    const image = setDragImage.mock.calls[0][0]
    expect(setDragImage).toHaveBeenCalledWith(image, 24, 24)
    expect(image.isConnected).toBe(true)
    frame.mock.calls[0][0]()
    expect(image.isConnected).toBe(false)
  } finally {
    global.requestAnimationFrame = originalFrame
  }
})
