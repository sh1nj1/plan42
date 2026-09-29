/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import Toasts from '../notice_bar/toasts'

describe('notice bar Toasts', () => {
  let layer
  let toasts

  beforeEach(() => {
    jest.useFakeTimers()
    layer = document.createElement('div')
    document.body.appendChild(layer)
    toasts = new Toasts(layer)
  })

  afterEach(() => {
    jest.useRealTimers()
    document.body.innerHTML = ''
  })

  test('adopt presents a server-rendered flash and hides it after 4s', async () => {
    const flash = document.createElement('div')
    flash.className = 'notice-toast'
    layer.appendChild(flash)
    toasts.adopt(flash)
    expect(flash.querySelector('.notice-toast__timer')).not.toBeNull()
    await jest.advanceTimersByTimeAsync(3999)
    expect(flash.isConnected).toBe(true)
    await jest.advanceTimersByTimeAsync(1)
    expect(flash.isConnected).toBe(false)
  })

  test('show replaces the current toast and animates the timer when supported', async () => {
    const original = Element.prototype.animate
    Element.prototype.animate = jest.fn(() => ({ finished: Promise.resolve() }))
    try {
      toasts.show('first')
      toasts.show('second')
      expect(layer.children).toHaveLength(1)
      expect(layer.textContent).toBe('second')
      const timer = layer.querySelector('.notice-toast__timer')
      expect(Element.prototype.animate.mock.contexts).toContain(timer)
    } finally {
      if (original) Element.prototype.animate = original
      else delete Element.prototype.animate
    }
  })

  test('action button hides the toast and runs the action', async () => {
    const run = jest.fn()
    toasts.show('Snoozed', { label: 'Undo', run })
    const toast = layer.querySelector('.notice-toast')
    toast.querySelector('button').click()
    expect(run).toHaveBeenCalledTimes(1)
    await Promise.resolve()
    await Promise.resolve()
    expect(toast.isConnected).toBe(false)
    // The auto-hide timer was cleared.
    expect(jest.getTimerCount()).toBe(0)
  })

  test('destroy clears the pending hide timer', () => {
    toasts.show('bye')
    expect(jest.getTimerCount()).toBe(1)
    toasts.destroy()
    expect(jest.getTimerCount()).toBe(0)
  })
})
