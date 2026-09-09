/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import CommonPopup from '../common_popup'

// Typeahead menus (command menu, mention menu) call showAt on every keystroke to
// re-anchor a popup that is already on screen. showAt used to blank the element
// to visibility:hidden and wait a frame before revealing it again, so the menu
// blinked off and back on once per character typed.
describe('CommonPopup re-show while already open', () => {
    let element
    let frames

    const build = ({ popupHeight = 100 } = {}) => {
        element = document.createElement('div')
        Object.defineProperty(element, 'offsetParent', { value: null, configurable: true })
        Object.defineProperty(element, 'offsetWidth', { get: () => 320, configurable: true })
        Object.defineProperty(element, 'offsetHeight', { get: () => popupHeight, configurable: true })
        document.body.appendChild(element)
        return new CommonPopup(element, { listElement: document.createElement('ul') })
    }

    const runFrames = () => {
        const pending = frames.splice(0)
        pending.forEach((fn) => fn())
    }

    beforeEach(() => {
        frames = []
        jest.spyOn(window, 'requestAnimationFrame').mockImplementation((fn) => {
            frames.push(fn)
            return frames.length
        })
        jest.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => { })
        global.requestAnimationFrame = window.requestAnimationFrame
        global.cancelAnimationFrame = window.cancelAnimationFrame
    })

    afterEach(() => {
        jest.restoreAllMocks()
        document.body.innerHTML = ''
    })

    test('the first open hides the popup for a frame while it is measured', () => {
        const popup = build()
        popup.showAt({ left: 10, top: 100, bottom: 120 })

        expect(element.style.display).toBe('block')
        expect(element.style.visibility).toBe('hidden')

        runFrames()
        expect(element.style.visibility).toBe('visible')
    })

    test('re-anchoring an open popup never blanks it', () => {
        const popup = build()
        popup.showAt({ left: 10, top: 100, bottom: 120 })
        runFrames()

        const seen = []
        for (const left of [20, 30, 40, 50]) {
            popup.showAt({ left, top: 100, bottom: 120 })
            seen.push(element.style.visibility)
        }

        expect(seen).toEqual(['visible', 'visible', 'visible', 'visible'])
        expect(element.style.display).toBe('block')
    })

    test('re-anchoring places the popup immediately instead of a frame late', () => {
        const popup = build()
        popup.showAt({ left: 10, top: 100, bottom: 120 })
        runFrames()
        expect(element.style.left).toBe('10px')

        // No frame is run: the new position must already be applied.
        popup.showAt({ left: 240, top: 100, bottom: 120 })
        expect(element.style.left).toBe('240px')
    })

    test('a popup flipped above the caret stays above when re-anchored', () => {
        // 400px popup with the caret pinned near the bottom of a 768px viewport:
        // it cannot fit below, so the first placement flips it above.
        const popup = build({ popupHeight: 400 })
        window.visualViewport = {
            offsetLeft: 0, offsetTop: 0, width: 1024, height: 768,
            addEventListener: () => { }, removeEventListener: () => { },
        }

        popup.showAt({ left: 200, top: 700, bottom: 720 })
        runFrames()
        expect(popup._placedAbove).toBe(true)
        const flippedTop = element.style.top

        popup.showAt({ left: 210, top: 700, bottom: 720 })
        expect(popup._placedAbove).toBe(true)
        expect(element.style.top).toBe(flippedTop)

        delete window.visualViewport
    })

    test('re-registers the outside-click listeners so a re-open cannot self-close', () => {
        const addSpy = jest.spyOn(document, 'addEventListener')
        const removeSpy = jest.spyOn(document, 'removeEventListener')
        const popup = build()

        popup.showAt({ left: 10, top: 100, bottom: 120 })
        runFrames()
        popup.showAt({ left: 20, top: 100, bottom: 120 })

        expect(removeSpy).toHaveBeenCalledWith('mousedown', popup.handleOutsideClick)
        runFrames()
        expect(addSpy).toHaveBeenCalledWith('mousedown', popup.handleOutsideClick)
        expect(popup.isOpen()).toBe(true)
    })

    test('hide() after a re-anchor still closes the popup', () => {
        const popup = build()
        popup.showAt({ left: 10, top: 100, bottom: 120 })
        runFrames()
        popup.showAt({ left: 20, top: 100, bottom: 120 })
        popup.hide()

        expect(element.style.display).toBe('none')
        expect(popup.isOpen()).toBe(false)
        // _placedAbove is recomputed by the next genuine open.
        popup.showAt({ left: 10, top: 100, bottom: 120 })
        expect(element.style.visibility).toBe('hidden')
    })
})
