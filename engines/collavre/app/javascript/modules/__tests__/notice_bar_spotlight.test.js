/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Spotlight, findTarget, rememberPendingSpotlight, takePendingSpotlight } from '../notice_bar/spotlight'

function visible(el, rect = { left: 20, top: 100, bottom: 130, width: 200, height: 30 }) {
  el.getClientRects = () => [rect]
  el.getBoundingClientRect = () => rect
  return el
}

describe('notice bar spotlight', () => {
  afterEach(() => {
    document.body.innerHTML = ''
    sessionStorage.clear()
    jest.restoreAllMocks()
  })

  describe('findTarget', () => {
    test('returns null without a selector or visible match', () => {
      expect(findTarget(null)).toBeNull()
      expect(findTarget('')).toBeNull()
      document.body.innerHTML = '<div class="t"></div>'
      expect(findTarget('.t')).toBeNull()
    })

    test('returns the first visible match, skipping visibility:hidden', () => {
      document.body.innerHTML = '<div class="t" id="a" style="visibility:hidden"></div><div class="t" id="b"></div>'
      document.querySelectorAll('.t').forEach((el) => visible(el))
      expect(findTarget('.t').id).toBe('b')
    })
  })

  describe('pending spotlight storage', () => {
    test('remembers and takes the key once', () => {
      rememberPendingSpotlight('m1')
      expect(sessionStorage.getItem('collavre:notice-spotlight')).toBe('m1')
      expect(takePendingSpotlight()).toBe('m1')
      expect(takePendingSpotlight()).toBeNull()
    })

    test('tolerates disabled storage', () => {
      jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('denied') })
      jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('denied') })
      expect(() => rememberPendingSpotlight('m1')).not.toThrow()
      expect(takePendingSpotlight()).toBeNull()
    })
  })

  describe('Spotlight', () => {
    test('show outlines the element, adds a tip below it and focuses inputs', () => {
      const input = visible(document.createElement('textarea'))
      input.scrollIntoView = jest.fn()
      document.body.appendChild(input)
      const spot = new Spotlight()
      spot.show(input, 'Type here')
      expect(input.classList.contains('notice-spot')).toBe(true)
      expect(input.scrollIntoView).toHaveBeenCalledWith({ block: 'nearest', behavior: 'smooth' })
      const tip = document.querySelector('.notice-spot-tip')
      expect(tip.textContent).toBe('Type here')
      expect(tip.getAttribute('role')).toBe('status')
      expect(tip.style.left).toBe('20px')
      expect(tip.style.top).toBe('140px')
      expect(document.activeElement).toBe(input)
    })

    test('reposition flips the tip above when it would overflow and clamps left', () => {
      const el = visible(document.createElement('div'), { left: -50, top: 700, bottom: 760, width: 100, height: 60 })
      document.body.appendChild(el)
      const spot = new Spotlight()
      spot.show(el, 'tip')
      const tip = spot.tip
      Object.defineProperty(tip, 'offsetHeight', { value: 40, configurable: true })
      Object.defineProperty(tip, 'offsetWidth', { value: 100, configurable: true })
      window.innerHeight = 768
      window.dispatchEvent(new Event('resize'))
      expect(tip.style.left).toBe('8px')
      expect(tip.style.top).toBe('650px')
    })

    test('show without tip, then click on the element clears it', () => {
      const el = visible(document.createElement('button'))
      document.body.appendChild(el)
      const spot = new Spotlight()
      spot.show(el)
      expect(document.querySelector('.notice-spot-tip')).toBeNull()
      expect(() => spot.reposition()).not.toThrow()
      el.click()
      expect(el.classList.contains('notice-spot')).toBe(false)
      expect(spot.el).toBeNull()
    })

    test('show replaces a previous spotlight and clear is idempotent', () => {
      const a = visible(document.createElement('div'))
      const b = visible(document.createElement('div'))
      document.body.append(a, b)
      const spot = new Spotlight()
      spot.show(a, 'A')
      spot.show(b, 'B')
      expect(a.classList.contains('notice-spot')).toBe(false)
      expect(document.querySelectorAll('.notice-spot-tip')).toHaveLength(1)
      spot.clear()
      spot.clear()
      expect(document.querySelectorAll('.notice-spot-tip')).toHaveLength(0)
    })
  })
})
