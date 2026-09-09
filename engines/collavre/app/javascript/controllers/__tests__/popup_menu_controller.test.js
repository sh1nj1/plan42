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
  let button

  beforeEach(async () => {
    document.body.innerHTML = ''
    notifyPopupOpen.mockClear()
    onOtherPopupOpen.mockClear()

    container = document.createElement('div')
    container.innerHTML = `
      <div data-controller="popup-menu">
        <button type="button" data-popup-menu-target="button">Open</button>
        <div id="test-menu" data-popup-menu-target="menu" style="display:none">
          <button class="popup-menu-item">Action</button>
        </div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('popup-menu', PopupMenuController)

    await new Promise(resolve => setTimeout(resolve, 0))

    const element = container.querySelector('[data-controller="popup-menu"]')
    controller = application.getControllerForElementAndIdentifier(element, 'popup-menu')
    menu = container.querySelector('#test-menu')
    button = container.querySelector('[data-popup-menu-target="button"]')

    Object.defineProperty(window, 'innerWidth', { writable: true, configurable: true, value: 360 })
    Object.defineProperty(window, 'innerHeight', { writable: true, configurable: true, value: 640 })
  })

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('uses fixed positioning to avoid creating scrollbars', async () => {
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 60, left: 20, right: 80, width: 60, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 200, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    expect(menu.style.position).toBe('fixed')
    expect(menu.style.visibility).toBe('')
    expect(menu.style.display).toBe('block')
  })

  test('positions below the button when there is enough space', async () => {
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 60, left: 20, right: 80, width: 60, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 200, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    // Menu should be placed below button: btnRect.bottom + gap = 60 + 4 = 64
    expect(menu.style.top).toBe('64px')
    expect(menu.style.left).toBe('20px')
  })

  test('positions above the button when more space above', async () => {
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 580, bottom: 600, left: 20, right: 80, width: 60, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 200, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    // Menu should be above button: btnRect.top - gap - menuH = 580 - 4 - 180 = 396
    expect(menu.style.top).toBe('396px')
  })

  test('right-aligns when _initialAlignRight is true', async () => {
    menu.classList.add('popup-menu-right')

    // Re-connect so controller picks up the initial state
    const element = container.querySelector('[data-controller="popup-menu"]')
    application.stop()
    application = Application.start()
    application.register('popup-menu', PopupMenuController)
    await new Promise(resolve => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(element, 'popup-menu')

    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 60, left: 200, right: 260, width: 60, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 200, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    // Right-align: left = btnRect.right - menuW = 260 - 200 = 60
    expect(menu.style.left).toBe('60px')
  })

  test('clamps menu to stay within viewport on narrow screens', async () => {
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 60, left: 300, right: 350, width: 50, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 220, width: 220, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    // Left would be 300, but 300 + 220 = 520 > 360 - 4 = 356
    // So left = 356 - 220 = 136
    expect(menu.style.left).toBe('136px')
  })

  test('hide() resets all inline styles', async () => {
    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 60, left: 20, right: 80, width: 60, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 200, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))

    controller.hide()

    expect(menu.style.display).toBe('none')
    expect(menu.style.position).toBe('')
    expect(menu.style.visibility).toBe('')
    expect(menu.style.top).toBe('')
    expect(menu.style.bottom).toBe('')
    expect(menu.style.left).toBe('')
    expect(menu.style.right).toBe('')
    expect(menu.style.maxWidth).toBe('')
    expect(menu.style.transform).toBe('')
  })

  test('hide() preserves initial popup-menu-right class', async () => {
    menu.classList.add('popup-menu-right')

    const element = container.querySelector('[data-controller="popup-menu"]')
    application.stop()
    application = Application.start()
    application.register('popup-menu', PopupMenuController)
    await new Promise(resolve => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(element, 'popup-menu')

    jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
      top: 40, bottom: 60, left: 20, right: 80, width: 60, height: 20
    })
    jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
      top: 0, bottom: 180, left: 0, right: 200, width: 200, height: 180
    })

    controller.show()
    await new Promise(resolve => requestAnimationFrame(resolve))
    controller.hide()

    expect(menu.classList.contains('popup-menu-right')).toBe(true)
  })

  // The mobile chat is a bottom sheet inside the *visual* viewport: the on-screen
  // keyboard shrinks that viewport and comments--presence lifts the sheet clear
  // of it, while window.innerHeight keeps reporting the full screen. Placing a
  // menu against innerHeight therefore drops it behind the keyboard on a phone
  // and nowhere near where the same menu lands on desktop.
  describe('visual viewport', () => {
    const stubVisualViewport = (rect) => {
      const listeners = {}
      const viewport = {
        ...rect,
        addEventListener: (type, handler) => { listeners[type] = handler },
        removeEventListener: (type) => { delete listeners[type] }
      }
      Object.defineProperty(window, 'visualViewport', {
        writable: true, configurable: true, value: viewport
      })
      return { viewport, listeners }
    }

    afterEach(() => {
      delete window.visualViewport
    })

    test('flips above the button when the keyboard covers the space below', async () => {
      stubVisualViewport({ width: 390, height: 344, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 234, bottom: 254, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 153, left: 0, right: 240, width: 240, height: 153
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // innerHeight (640) would leave room below and hide the menu behind the
      // keyboard; against the 344px visual viewport it must flip above:
      // 234 - 4 - 153 = 77
      expect(menu.style.top).toBe('77px')
    })

    test('clamps into the visible strip when the visual viewport is offset', async () => {
      stubVisualViewport({ width: 390, height: 300, offsetLeft: 0, offsetTop: 200 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 210, bottom: 230, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 400, left: 0, right: 240, width: 240, height: 400
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // Taller than the strip either way, so it clamps to the strip's top edge
      // (200 + 4) instead of the document's.
      expect(menu.style.top).toBe('204px')
    })

    test('re-places the open menu when the keyboard resizes the viewport', async () => {
      const { viewport, listeners } = stubVisualViewport({
        width: 390, height: 844, offsetLeft: 0, offsetTop: 0
      })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 234, bottom: 254, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 153, left: 0, right: 240, width: 240, height: 153
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))
      expect(menu.style.top).toBe('258px')

      viewport.height = 344
      listeners.resize?.()
      await new Promise(resolve => requestAnimationFrame(resolve))

      expect(menu.style.top).toBe('77px')
    })

    test('drops the viewport listeners on hide', async () => {
      const { listeners } = stubVisualViewport({
        width: 390, height: 844, offsetLeft: 0, offsetTop: 0
      })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 234, bottom: 254, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 153, left: 0, right: 240, width: 240, height: 153
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))
      controller.hide()

      expect(listeners.resize).toBeUndefined()
      expect(listeners.scroll).toBeUndefined()
    })
  })
})
