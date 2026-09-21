/**
 * @jest-environment jsdom
 */
import CommonPopup from '../common_popup'

// Cage-inside-bounds positioning: when a boundsElement is passed to showAt,
// updatePosition must clamp the popup within that element's rect (not the
// viewport) and cap its size so a long list scrolls inside instead of spilling.
describe('CommonPopup bounds clamping', () => {
    const BOUNDS = { left: 100, top: 100, right: 500, bottom: 700, width: 400, height: 600 }

    let element, boundsElement

    const build = ({ popupWidth, popupHeight }) => {
        boundsElement = document.createElement('div')
        boundsElement.getBoundingClientRect = () => BOUNDS

        element = document.createElement('div')
        // offsetParent is the bounds (chat box); parentRect === BOUNDS.
        Object.defineProperty(element, 'offsetParent', { value: boundsElement, configurable: true })
        Object.defineProperty(element, 'offsetWidth', { value: popupWidth, configurable: true })
        Object.defineProperty(element, 'offsetHeight', { value: popupHeight, configurable: true })
        document.body.appendChild(element)
        return new CommonPopup(element, { listElement: document.createElement('ul') })
    }

    afterEach(() => { document.body.innerHTML = '' })

    test('clamps an anchor near the right/bottom edge back inside the bounds', () => {
        const popup = build({ popupWidth: 320, popupHeight: 400 })
        popup._boundsElement = boundsElement
        // Anchor button hard against the right edge — would overflow the box.
        // maxLeft = right - width - pad = 500 - 320 - 8 = 172; parent coords: 172 - 100 = 72
        popup.updatePosition({ left: 450, bottom: 130 })
        expect(element.style.left).toBe('72px')
        // viewportTop = 130 + 4 = 134; within [108, 292] → 134; parent coords: 134 - 100 = 34
        expect(element.style.top).toBe('34px')
    })

    test('caps max size to fit inside the bounds', () => {
        const popup = build({ popupWidth: 320, popupHeight: 400 })
        popup._boundsElement = boundsElement
        popup.updatePosition({ left: 200, bottom: 200 })
        // inner box = width - 2*pad
        expect(element.style.maxWidth).toBe('384px')
        // Height is capped to the space under the anchor rather than the whole
        // box (700 - 8 - 204), so content arriving later cannot spill past it.
        expect(element.style.maxHeight).toBe('488px')
    })

    test('falls back to viewport clamping when no bounds element is set', () => {
        const popup = build({ popupWidth: 320, popupHeight: 400 })
        popup._boundsElement = null
        // jsdom viewport defaults 1024x768; anchor at 0 → left clamps to padding 8, parent 0
        Object.defineProperty(element, 'offsetParent', { value: null, configurable: true })
        popup.updatePosition({ left: 0, bottom: 0 })
        // Space below the anchor inside the viewport: 768 - 8 - 4.
        expect(element.style.maxHeight).toBe('756px')
        expect(element.style.left).toBe('8px')
        // maxWidth stays a stylesheet concern when unbounded.
        expect(element.style.maxWidth).toBe('')
    })
})
