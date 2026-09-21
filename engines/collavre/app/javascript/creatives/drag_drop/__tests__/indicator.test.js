/** @jest-environment jsdom */
import { jest } from '@jest/globals'

beforeEach(() => {
  jest.resetModules()
  document.body.innerHTML = ''
})

afterEach(() => jest.restoreAllMocks())

test('both adapters reuse one decorative badge and restore it after a body replacement', async () => {
  const { initIndicator, showLinkHover, hideLinkHover } = await import('../indicator')
  showLinkHover(1, 2)
  hideLinkHover()
  initIndicator()
  initIndicator()
  expect(document.querySelectorAll('.creative-link-drop-indicator')).toHaveLength(1)
  const badge = document.querySelector('.creative-link-drop-indicator')
  expect(badge.getAttribute('aria-hidden')).toBe('true')
  document.body.innerHTML = ''
  initIndicator()
  expect(document.querySelector('.creative-link-drop-indicator')).toBe(badge)
  showLinkHover(30, 40)
  expect([badge.style.display, badge.style.left, badge.style.top]).toEqual(['block', '30px', '40px'])
  hideLinkHover()
  expect(badge.style.display).toBe('none')
})

test('initialization before DOM readiness attaches after DOMContentLoaded', async () => {
  jest.spyOn(document, 'readyState', 'get').mockReturnValue('loading')
  const { initIndicator } = await import('../indicator')
  initIndicator()
  expect(document.querySelector('.creative-link-drop-indicator')).toBeNull()
  document.dispatchEvent(new Event('DOMContentLoaded'))
  expect(document.querySelectorAll('.creative-link-drop-indicator')).toHaveLength(1)
})
