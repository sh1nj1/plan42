/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import CommonPopup from '../common_popup'

// Viewport-fit placement: a popup anchored to a caret sitting just above the
// chat composer has almost no room below it. updatePosition must flip above the
// anchor, cap the popup to the space it actually has, and re-run once async
// content (the creative mini-tree) has replaced the "Loading…" placeholder.
describe('CommonPopup viewport-fit placement', () => {
    const VIEWPORT_WIDTH = 1024

    let element

    // offsetHeight is mutable so a test can simulate the popup growing after its
    // async content lands, which is the whole point of reposition().
    const build = ({ popupWidth = 320, popupHeight = 400 } = {}) => {
        element = document.createElement('div')
        Object.defineProperty(element, 'offsetParent', { value: null, configurable: true })
        Object.defineProperty(element, 'offsetWidth', { get: () => popupWidth, configurable: true })
        Object.defineProperty(element, 'offsetHeight', {
            get: () => element._testHeight,
            configurable: true,
        })
        element._testHeight = popupHeight
        document.body.appendChild(element)
        return new CommonPopup(element, { listElement: document.createElement('ul') })
    }

    const stubVisualViewport = (height) => {
        const listeners = {}
        window.visualViewport = {
            offsetLeft: 0,
            offsetTop: 0,
            width: VIEWPORT_WIDTH,
            height,
            addEventListener: (type, fn) => { listeners[type] = fn },
            removeEventListener: (type) => { delete listeners[type] },
        }
        return listeners
    }

    afterEach(() => {
        document.body.innerHTML = ''
        delete window.visualViewport
    })

    test('flips above the anchor when the popup does not fit below it', () => {
        const popup = build({ popupHeight: 400 })
        // Caret on the last line of a composer pinned to the bottom: only 48px
        // of viewport under it, far less than the popup's 400px.
        popup.updatePosition({ left: 200, top: 700, bottom: 720 })

        // top = anchorTop - gap - height = 700 - 4 - 400
        expect(element.style.top).toBe('296px')
        // Space above = 700 - 4 - 8 = 688, and the popup fits in it untouched.
        expect(element.style.maxHeight).toBe('688px')
    })

    test('stays below the anchor when there is room for the popup', () => {
        const popup = build({ popupHeight: 400 })
        popup.updatePosition({ left: 200, top: 80, bottom: 100 })

        expect(element.style.top).toBe('104px')
        // Capped to the space below (768 - 8 - 104) so later growth still fits.
        expect(element.style.maxHeight).toBe('656px')
    })

    test('caps the popup to the larger side when it fits on neither', () => {
        const popup = build({ popupHeight: 400 })
        // spaceBelow = 768 - 8 - 564 = 196; spaceAbove = 360 - 4 - 8 = 348.
        popup.updatePosition({ left: 200, top: 360, bottom: 560 })

        expect(element.style.maxHeight).toBe('348px')
        // Rendered height is now the cap, so the top edge sits at the padding.
        expect(element.style.top).toBe('8px')
    })

    test('never shrinks the popup below a usable minimum', () => {
        const popup = build({ popupHeight: 400 })
        // Anchor pinned to the very bottom: nothing below, 8px above.
        popup.updatePosition({ left: 200, top: 20, bottom: 760 })

        expect(element.style.maxHeight).toBe('160px')
    })

    test('measures the popup unconstrained so a stale cap cannot stick', () => {
        const popup = build({ popupHeight: 400 })
        // A previous placement left a tiny cap behind.
        element.style.maxHeight = '130px'
        popup.updatePosition({ left: 200, top: 700, bottom: 720 })

        // Had the 130px cap been read back as the popup's height, it would have
        // "fit" below the caret and stayed pinned there.
        expect(element.style.top).toBe('296px')
    })

    test('measures the visual viewport, not the layout viewport', () => {
        // The on-screen keyboard covers the bottom 300px of a 768px window.
        stubVisualViewport(468)
        const popup = build({ popupHeight: 400 })
        popup.updatePosition({ left: 200, top: 400, bottom: 420 })

        // spaceBelow against the keyboard top = 468 - 8 - 424 = 36, so it flips;
        // spaceAbove = 400 - 4 - 8 = 388, which becomes the cap.
        expect(element.style.maxHeight).toBe('388px')
        expect(element.style.top).toBe('8px')
    })

    describe('reposition after async content', () => {
        let realRaf

        beforeEach(() => {
            jest.useFakeTimers()
            realRaf = window.requestAnimationFrame
            window.requestAnimationFrame = (cb) => setTimeout(cb, 0)
        })

        afterEach(() => {
            window.requestAnimationFrame = realRaf
            jest.useRealTimers()
        })

        const openAndSettle = (popup, anchorRect) => {
            popup.showAt(anchorRect)
            // showAt defers positioning by one animation frame.
            jest.advanceTimersByTime(20)
        }

        test('re-places the popup once its content has grown', () => {
            const popup = build({ popupHeight: 400 })
            // Opens while still showing "Loading…": header + input only.
            element._testHeight = 130
            openAndSettle(popup, { left: 200, top: 700, bottom: 720 })
            expect(element.style.top).toBe('566px')

            // The mini-tree lands and the popup grows to its full height.
            element._testHeight = 400
            popup.reposition()

            expect(element.style.top).toBe('296px')
        })

        test('keeps the popup above the anchor once flipped, even if it later shrinks', () => {
            const popup = build({ popupHeight: 400 })
            openAndSettle(popup, { left: 200, top: 700, bottom: 720 })
            expect(element.style.top).toBe('296px')

            // Collapsing every tree node shrinks the popup back to a size that
            // would fit below — hopping across the caret would be jarring.
            element._testHeight = 120
            popup.reposition()

            expect(element.style.top).toBe('576px')
        })

        test('does nothing when the popup is closed', () => {
            const popup = build({ popupHeight: 400 })
            popup.reposition()
            expect(element.style.top).toBe('')
        })

        test('re-places on visual viewport resize while open, and unbinds on hide', () => {
            const listeners = stubVisualViewport(768)
            const popup = build({ popupHeight: 400 })
            openAndSettle(popup, { left: 200, top: 300, bottom: 320 })
            // spaceBelow = 768 - 8 - 324 = 436, enough for 400px.
            expect(element.style.top).toBe('324px')
            expect(element.style.maxHeight).toBe('436px')
            expect(typeof listeners.resize).toBe('function')

            // The on-screen keyboard opens and eats the bottom of the viewport.
            window.visualViewport.height = 400
            listeners.resize()

            // spaceBelow = 400 - 8 - 324 = 68; spaceAbove = 300 - 4 - 8 = 288.
            expect(element.style.maxHeight).toBe('288px')
            expect(element.style.top).toBe('8px')

            popup.hide()
            expect(listeners.resize).toBeUndefined()
        })
    })
})
