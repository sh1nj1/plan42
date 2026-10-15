/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import LoadingController from '../loading_controller'

describe('chat emoji loading', () => {
  let controller
  beforeEach(() => {
    jest.useFakeTimers()
    controller = Object.create(LoadingController.prototype)
    const element = document.createElement('div')
    element.innerHTML = '<span class="creative-loading-dot">.</span>'.repeat(3)
    Object.defineProperty(controller, 'element', { value: element })
  })
  afterEach(() => {
    controller.disconnect()
    document.body.style.removeProperty('--creative-loading-emojis')
    document.documentElement.style.removeProperty('--creative-loading-emojis')
    jest.useRealTimers()
  })
  const dots = (controller) => [...controller.element.children].map(dot => dot.textContent)

  test('moves theme emojis through three dots and cycles emojis', () => {
    document.body.style.setProperty('--creative-loading-emojis', '"🚀,🧠"')
    controller.connect()
    expect(dots(controller)).toEqual(['.', '.', '.'])
    for (const expected of [['.', '.', '🚀'], ['.', '🚀', '.'], ['🚀', '.', '.'], ['.', '.', '.'], ['.', '.', '🧠']]) {
      jest.advanceTimersByTime(120)
      expect(dots(controller)).toEqual(expected)
    }
    controller.disconnect()
    jest.advanceTimersByTime(120)
    expect(dots(controller)).toEqual(['.', '.', '🧠'])
    expect(jest.getTimerCount()).toBe(0)
  })

  test.each([['"✨🤝"', '✨'], ['', '🎨']])('uses root theme or fallback emojis (%s)', (value, emoji) => {
    document.documentElement.style.setProperty('--creative-loading-emojis', value)
    controller.connect()
    jest.advanceTimersByTime(120)
    expect(dots(controller)).toEqual(['.', '.', emoji])
  })
})
