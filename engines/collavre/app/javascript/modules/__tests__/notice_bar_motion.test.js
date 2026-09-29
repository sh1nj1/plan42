/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { animate, cancelAnimations, confetti, prefersReducedMotion, sleep, EASE, HOLD, FADE_OUT } from '../notice_bar/motion'

function stubMatchMedia(matches) {
  window.matchMedia = jest.fn(() => ({ matches }))
}

describe('notice bar motion', () => {
  afterEach(() => {
    delete window.matchMedia
    document.body.innerHTML = ''
    jest.useRealTimers()
  })

  test('exports easing and keyframe presets', () => {
    expect(EASE.spring).toMatch(/cubic-bezier/)
    expect(HOLD).toHaveLength(2)
    expect(FADE_OUT[1]).toEqual({ opacity: 0 })
  })

  test('prefersReducedMotion falls back to false without matchMedia', () => {
    delete window.matchMedia
    expect(prefersReducedMotion()).toBe(false)
    stubMatchMedia(true)
    expect(prefersReducedMotion()).toBe(true)
    expect(window.matchMedia).toHaveBeenCalledWith('(prefers-reduced-motion: reduce)')
  })

  test('sleep resolves after the given delay', async () => {
    jest.useFakeTimers()
    const done = jest.fn()
    sleep(100).then(done)
    await jest.advanceTimersByTimeAsync(99)
    expect(done).not.toHaveBeenCalled()
    await jest.advanceTimersByTimeAsync(1)
    expect(done).toHaveBeenCalled()
  })

  test('animate resolves immediately without the Web Animations API', async () => {
    await expect(animate(null, [], {})).resolves.toBeUndefined()
    await expect(animate(document.createElement('div'), [], {})).resolves.toBeUndefined()
  })

  test('animate runs the full keyframes with default fill', async () => {
    stubMatchMedia(false)
    const el = { animate: jest.fn(() => ({ finished: Promise.resolve('ok') })) }
    await expect(animate(el, ['k'], { duration: 500 })).resolves.toBe('ok')
    expect(el.animate).toHaveBeenCalledWith(['k'], { fill: 'none', duration: 500 })
  })

  test('animate uses reduced keyframes and caps timing under reduced motion', async () => {
    stubMatchMedia(true)
    const el = { animate: jest.fn(() => ({ finished: Promise.resolve() })) }
    await animate(el, ['k'], { duration: 500, delay: 100, easing: 'ease' }, ['r'])
    expect(el.animate).toHaveBeenCalledWith(['r'], { fill: 'none', duration: 160, delay: 0, easing: 'linear' })
    await animate(el, ['k'], {})
    expect(el.animate).toHaveBeenLastCalledWith([{ opacity: 0 }, { opacity: 1 }], { fill: 'none', duration: 160, delay: 0, easing: 'linear' })
  })

  test('animate swallows cancelled animations', async () => {
    const el = { animate: () => ({ finished: Promise.reject(new Error('aborted')) }) }
    await expect(animate(el, [], {})).resolves.toBeUndefined()
  })

  test('cancelAnimations cancels every animation in the subtree', () => {
    const a = { cancel: jest.fn() }
    const el = { getAnimations: jest.fn(() => [a]) }
    cancelAnimations(el)
    expect(el.getAnimations).toHaveBeenCalledWith({ subtree: true })
    expect(a.cancel).toHaveBeenCalled()
    expect(() => cancelAnimations(null)).not.toThrow()
    expect(() => cancelAnimations({})).not.toThrow()
  })

  test('confetti does nothing under reduced motion or without an element', () => {
    stubMatchMedia(true)
    confetti(document.createElement('div'))
    stubMatchMedia(false)
    confetti(null)
    expect(document.querySelectorAll('.notice-confetti')).toHaveLength(0)
  })

  test('confetti spawns pieces that remove themselves when done', async () => {
    const from = document.createElement('div')
    document.body.appendChild(from)
    const original = Element.prototype.animate
    Element.prototype.animate = jest.fn(() => ({ finished: Promise.resolve() }))
    try {
      confetti(from, 3)
      const pieces = document.querySelectorAll('.notice-confetti')
      expect(pieces).toHaveLength(3)
      expect(pieces[0].style.background).toBe('var(--notice-announcement-start)')
      expect(pieces[1].style.background).toBe('var(--color-success)')
      expect(pieces[2].style.background).toBe('var(--notice-feature-start)')
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
      expect(document.querySelectorAll('.notice-confetti')).toHaveLength(0)
    } finally {
      if (original) Element.prototype.animate = original
      else delete Element.prototype.animate
    }
  })

  test('confetti defaults to 46 pieces', () => {
    confetti(document.body.appendChild(document.createElement('div')))
    expect(document.querySelectorAll('.notice-confetti')).toHaveLength(46)
  })
})
