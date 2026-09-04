/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import TouchDragHandler from '../touch_drag'

describe('TouchDragHandler tap support', () => {
  test('calls onTap when a single-element gesture ends before the long press', () => {
    jest.useFakeTimers()
    const container = document.createElement('button')
    const onTap = jest.fn()
    const handler = new TouchDragHandler({
      container,
      singleElement: true,
      dropTargetSelector: '.drop-target',
      onTap,
    })
    const preventDefault = jest.fn()

    handler._handleTouchStart({
      touches: [{ clientX: 10, clientY: 20 }],
      preventDefault,
    })
    handler._handleTouchEnd({})

    expect(preventDefault).toHaveBeenCalled()
    expect(onTap).toHaveBeenCalled()
    handler.destroy()
    jest.useRealTimers()
  })
})
