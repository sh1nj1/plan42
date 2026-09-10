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
    expect(menu.style.maxHeight).toBe('')
    expect(menu.style.overflowY).toBe('')
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

    test('caps a menu taller than the strip instead of overflowing it', async () => {
      stubVisualViewport({ width: 390, height: 300, offsetLeft: 0, offsetTop: 200 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 210, bottom: 230, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 400, left: 0, right: 240, width: 240, height: 400
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // 400px of items into a 300px strip: sit below the button (230 + 4) and
      // cap to the space left under it (496 - 234), scrolling the rest.
      expect(menu.style.top).toBe('234px')
      expect(menu.style.maxHeight).toBe('262px')
      expect(menu.style.overflowY).toBe('auto')
    })

    // A cron popup listing many tasks is taller than the visible viewport once
    // the keyboard is up. Clamping only its top leaves the lower actions behind
    // the keyboard with nothing to scroll, since .popup-menu is overflow:hidden.
    test('caps the menu to the region so its lower actions stay reachable', async () => {
      stubVisualViewport({ width: 390, height: 344, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 100, bottom: 120, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 600, left: 0, right: 240, width: 240, height: 600
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      expect(menu.style.top).toBe('124px')
      expect(menu.style.maxHeight).toBe('216px')
      expect(menu.style.overflowY).toBe('auto')
      // Bottom edge lands on the region's padded edge, not past it.
      expect(124 + 216).toBe(344 - 4)
    })

    test('preserves a smaller stylesheet height cap when there is more room', async () => {
      const style = document.createElement('style')
      style.textContent = '.cron-badge-popup { max-height: 480px; }'
      document.head.appendChild(style)
      menu.classList.add('cron-badge-popup')
      stubVisualViewport({ width: 390, height: 1000, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 900, bottom: 920, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 480, left: 0, right: 240, width: 240, height: 480
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // The 892px above the trigger must not replace the cron popup's 480px
      // stylesheet cap after it was measured at that height.
      expect(menu.style.maxHeight).toBe('480px')
      expect(menu.style.top).toBe('416px')

      style.remove()
    })

    // Both sides are under the sliver floor on a short phone with the keyboard
    // up, so the floor wins and the menu overhangs the button — then the bottom
    // clamp slides it back up inside the strip rather than off the screen.
    test('pulls a floored menu back inside the strip', async () => {
      stubVisualViewport({ width: 390, height: 200, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 90, bottom: 110, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 300, left: 0, right: 240, width: 240, height: 300
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // Floor of 120 against 82px of room below: placed at 114, clamped so its
      // bottom lands on 196 instead of 234.
      expect(menu.style.maxHeight).toBe('120px')
      expect(menu.style.top).toBe('76px')
    })

    // Pinch zoom shrinks the visual viewport below the menu's stylesheet floor
    // (220px, 240px for the comment user popup). CSS resolves min-width over
    // max-width, so capping the width alone leaves the menu wider than the
    // screen with its right edge off in the part you cannot scroll to.
    const stubStylesheetMinWidth = (value) => {
      const style = document.createElement('style')
      style.textContent = `.popup-menu { min-width: ${value}; }`
      document.head.appendChild(style)
      menu.classList.add('popup-menu')
      return style
    }

    test('drops the stylesheet minimum when the strip is narrower than it', async () => {
      const style = stubStylesheetMinWidth('240px')
      stubVisualViewport({ width: 195, height: 400, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 40, bottom: 60, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 153, left: 0, right: 240, width: 240, height: 153
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // 195 - 4 * 2 of usable width: the floor has to come down with the cap,
      // otherwise the menu stays 240px wide however narrow the screen gets.
      expect(menu.style.maxWidth).toBe('187px')
      expect(menu.style.minWidth).toBe('187px')

      style.remove()
    })

    test('leaves the stylesheet minimum alone when there is room for it', async () => {
      const style = stubStylesheetMinWidth('240px')
      stubVisualViewport({ width: 390, height: 400, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 40, bottom: 60, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 153, left: 0, right: 240, width: 240, height: 153
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      expect(menu.style.minWidth).toBe('')

      style.remove()
    })

    // Pinching back out has to give the menu its designed width again, and a
    // menu left narrow after hide() would open wrong on the next click.
    test('restores the minimum when the strip widens again', async () => {
      const style = stubStylesheetMinWidth('240px')
      const { listeners } = stubVisualViewport({ width: 195, height: 400, offsetLeft: 0, offsetTop: 0 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 40, bottom: 60, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 153, left: 0, right: 240, width: 240, height: 153
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))
      expect(menu.style.minWidth).toBe('187px')

      window.visualViewport.width = 390
      listeners.resize()
      expect(menu.style.minWidth).toBe('')

      controller.hide()
      expect(menu.style.minWidth).toBe('')

      style.remove()
    })

    // The button can sit above the strip entirely (page scrolled under a pinned
    // sheet). The cap must respect the whole strip, not just the room below.
    test('never grows past the strip when the button is above it', async () => {
      stubVisualViewport({ width: 390, height: 300, offsetLeft: 0, offsetTop: 200 })
      jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({
        top: 120, bottom: 140, left: 9, right: 29, width: 20, height: 20
      })
      jest.spyOn(menu, 'getBoundingClientRect').mockReturnValue({
        top: 0, bottom: 400, left: 0, right: 240, width: 240, height: 400
      })

      controller.show()
      await new Promise(resolve => requestAnimationFrame(resolve))

      // Capped to the strip (300 - 4 * 2) and clamped down to its top edge.
      expect(menu.style.maxHeight).toBe('292px')
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
