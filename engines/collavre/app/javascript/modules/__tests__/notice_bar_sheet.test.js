/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import NoticeSheet from '../notice_bar/sheet'

const i18n = { more: 'More', dismiss: 'Dismiss', close: 'Close', later: 'Later', mission_hint: 'hint' }
const item = { key: 'k1', kind: 'mission', icon: 'i', tag: 'Tag', title: 'Title', summary: 'S', body: 'B', cta: 'Go' }

function makeStrip() {
  const strip = document.createElement('div')
  strip.tabIndex = 0
  strip.getBoundingClientRect = () => ({ left: 0, top: 0, width: 800, height: 40 })
  document.body.appendChild(strip)
  return strip
}

describe('NoticeSheet', () => {
  let originalAnimate

  beforeEach(() => {
    originalAnimate = Element.prototype.animate
    window.innerWidth = 1024
    window.innerHeight = 768
  })

  afterEach(() => {
    if (originalAnimate) Element.prototype.animate = originalAnimate
    else delete Element.prototype.animate
    delete Element.prototype.getAnimations
    delete window.matchMedia
    document.body.innerHTML = ''
  })

  test('constructs a hidden dialog and backdrop, destroy removes them', () => {
    const sheet = new NoticeSheet(i18n)
    expect(sheet.el.getAttribute('role')).toBe('dialog')
    expect(sheet.el.getAttribute('aria-modal')).toBe('true')
    expect(sheet.isOpen).toBe(false)
    expect(document.body.contains(sheet.backdrop)).toBe(true)
    sheet.destroy()
    expect(document.body.contains(sheet.el)).toBe(false)
    expect(document.body.contains(sheet.backdrop)).toBe(false)
  })

  test('targetBox is a centered dialog on desktop and a bottom sheet on mobile', () => {
    const sheet = new NoticeSheet(i18n)
    expect(sheet.targetBox(200)).toEqual({ box: { left: 232, top: 264, width: 560, height: 200 }, radius: '16px' })
    expect(sheet.targetBox(760).box.top).toBe(24)
    window.innerWidth = 400
    expect(sheet.targetBox(300)).toEqual({ box: { left: 0, top: 468, width: 400, height: 300 }, radius: '18px 18px 0px 0px' })
  })

  test('open morphs from the strip with full motion and focuses the CTA; close shrinks back', async () => {
    Element.prototype.animate = jest.fn(() => ({ finished: Promise.resolve() }))
    const cancel = jest.fn()
    Element.prototype.getAnimations = jest.fn(() => [{ cancel }])
    const strip = makeStrip()
    const sheet = new NoticeSheet(i18n)
    await sheet.open(item, strip)
    expect(sheet.isOpen).toBe(true)
    expect(sheet.el.className).toBe('notice-sheet notice-kind-mission')
    expect(sheet.el.style.width).toBe('560px')
    expect(sheet.el.style.borderRadius).toBe('16px')
    expect(strip.style.visibility).toBe('hidden')
    expect(sheet.backdrop.classList.contains('is-open')).toBe(true)
    expect(document.activeElement).toBe(sheet.parts.cta)
    // backdrop, ghost, content, icon, sheet
    expect(Element.prototype.animate).toHaveBeenCalledTimes(5)

    Element.prototype.animate.mockClear()
    await sheet.close(strip)
    expect(sheet.isOpen).toBe(false)
    expect(sheet.backdrop.classList.contains('is-open')).toBe(false)
    expect(cancel).toHaveBeenCalled()
    expect(strip.style.visibility).toBe('')
    expect(document.activeElement).toBe(strip)
    // backdrop, content, ghost, sheet, strip flash
    expect(Element.prototype.animate).toHaveBeenCalledTimes(5)
  })

  test('reduced motion fades instead of morphing', async () => {
    window.matchMedia = () => ({ matches: true })
    Element.prototype.animate = jest.fn(() => ({ finished: Promise.resolve() }))
    window.innerWidth = 400
    const strip = makeStrip()
    const sheet = new NoticeSheet(i18n)
    await sheet.open(item, strip)
    expect(sheet.parts.ghost.style.opacity).toBe('0')
    expect(sheet.el.style.width).toBe('400px')
    expect(sheet.el.style.borderRadius).toBe('18px 18px 0px 0px')
    await sheet.close(strip)
    expect(sheet.isOpen).toBe(false)
  })

  test('close fades out when the strip is gone', async () => {
    const strip = makeStrip()
    const sheet = new NoticeSheet(i18n)
    await sheet.open(item, strip)
    strip.remove()
    await sheet.close(strip)
    expect(sheet.isOpen).toBe(false)
    await sheet.open(item, makeStrip())
    await sheet.close(null)
    expect(sheet.isOpen).toBe(false)
  })
})
