/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const notifyPopupOpen = jest.fn()
const onOtherPopupOpen = jest.fn(() => () => {})

jest.unstable_mockModule('../../lib/gnb_popup_manager', () => ({
  __esModule: true,
  notifyPopupOpen,
  onOtherPopupOpen
}))

const { default: PopupMenuController } = await import('../popup_menu_controller')

describe('PopupMenuController', () => {
  let application
  let container
  let controller
  let menu

  beforeEach(async () => {
    document.body.innerHTML = ''
    notifyPopupOpen.mockClear()
    onOtherPopupOpen.mockClear()

    container = document.createElement('div')
    container.innerHTML = `
      <div data-controller="popup-menu">
        <button type="button" data-popup-menu-target="button">Open</button>
        <div id="test-menu" data-popup-menu-target="menu" style="display:none"></div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('popup-menu', PopupMenuController)

    await new Promise(resolve => setTimeout(resolve, 0))

    const element = container.querySelector('[data-controller="popup-menu"]')
    controller = application.getControllerForElementAndIdentifier(element, 'popup-menu')
    menu = container.querySelector('#test-menu')

    Object.defineProperty(window, 'innerWidth', { writable: true, configurable: true, value: 360 })
    Object.defineProperty(window, 'innerHeight', { writable: true, configurable: true, value: 640 })
  })

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('flips upward when there is more space above than below', async () => {
    const rects = [
      { top: 520, bottom: 700, left: 20, right: 220, width: 200, height: 180 },
      { top: 336, bottom: 516, left: 20, right: 220, width: 200, height: 180 }
    ]
    let callCount = 0
    jest.spyOn(menu, 'getBoundingClientRect').mockImplementation(() => rects[Math.min(callCount++, rects.length - 1)])

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    expect(menu.style.bottom).toBe('calc(100% + 4px)')
    expect(menu.style.top).toBe('auto')
  })

  test('stays below when there is more space below than above', async () => {
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 40,
      bottom: 220,
      left: 20,
      right: 220,
      width: 200,
      height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    expect(menu.style.top).toBe('calc(100% + 4px)')
    expect(menu.style.bottom).toBe('auto')
  })

  test('switches to right alignment when left alignment would overflow the viewport', async () => {
    const rects = [
      { top: 80, bottom: 260, left: 260, right: 460, width: 200, height: 180 },
      { top: 80, bottom: 260, left: 140, right: 340, width: 200, height: 180 }
    ]
    let callCount = 0
    jest.spyOn(menu, 'getBoundingClientRect').mockImplementation(() => rects[Math.min(callCount++, rects.length - 1)])

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    expect(menu.classList.contains('popup-menu-right')).toBe(true)
  })

  test('preserves initial right alignment through show/hide cycle', async () => {
    // Simulate a menu rendered with align: :right (server adds popup-menu-right)
    menu.classList.add('popup-menu-right')

    // Re-connect so controller picks up the initial state
    const element = container.querySelector('[data-controller="popup-menu"]')
    application.stop()
    application = Application.start()
    application.register('popup-menu', PopupMenuController)
    await new Promise(resolve => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(element, 'popup-menu')

    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 80, bottom: 260, left: 20, right: 220, width: 200, height: 180
    })

    // show() should preserve popup-menu-right
    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))
    expect(menu.classList.contains('popup-menu-right')).toBe(true)

    // hide() should also preserve it
    controller.hide()
    expect(menu.classList.contains('popup-menu-right')).toBe(true)
  })

  test('hide() cleans up inline styles set by show()', async () => {
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 220, left: 20, right: 220, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    // Verify show() set some styles
    expect(menu.style.display).toBe('block')

    controller.hide()

    expect(menu.style.display).toBe('none')
    expect(menu.style.top).toBe('')
    expect(menu.style.bottom).toBe('')
    expect(menu.style.maxWidth).toBe('')
    expect(menu.style.transform).toBe('')
  })
})
