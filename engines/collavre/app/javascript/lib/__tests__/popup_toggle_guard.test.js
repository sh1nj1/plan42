/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import PopupToggleGuard from '../popup_toggle_guard'

describe('PopupToggleGuard', () => {
    let guard, button

    beforeEach(() => {
        guard = new PopupToggleGuard()
        button = document.createElement('button')
        document.body.appendChild(button)
        button.setPointerCapture = jest.fn()
        jest.spyOn(button, 'getBoundingClientRect').mockReturnValue({ left: 10, right: 20, top: 10, bottom: 20 })
    })

    afterEach(() => {
        document.body.innerHTML = ''
        jest.useRealTimers()
        jest.restoreAllMocks()
    })

    const down = (overrides = {}) =>
        ({ isPrimary: true, button: 0, pointerId: 1, currentTarget: button, ...overrides })

    test('arms only while the popup is open, capturing the pointer', () => {
        guard.prepare(down(), false)
        expect(guard.pointerDown).toBe(false)
        expect(button.setPointerCapture).not.toHaveBeenCalled()

        guard.prepare(down(), true)
        expect(guard.pointerDown).toBe(true)
        expect(button.setPointerCapture).toHaveBeenCalledWith(1)
    })

    test('ignores non-primary pointers and non-left buttons', () => {
        guard.prepare(down({ isPrimary: false }), true)
        guard.prepare(down({ button: 2 }), true)
        expect(guard.pointerDown).toBe(false)
    })

    test('consume swallows the click that follows an armed gesture, once', () => {
        guard.prepare(down(), true)

        expect(guard.consume()).toBe(true)
        expect(guard.consume()).toBe(false)
    })

    test('releasing outside the button disarms it so the click still opens', () => {
        guard.prepare(down(), true)
        guard.finish({ currentTarget: button, clientX: 100, clientY: 100, pointerId: 1 })

        expect(guard.consume()).toBe(false)
    })

    test('a completed in-button gesture is cleared after the click task', () => {
        jest.useFakeTimers()
        guard.prepare(down(), true)
        guard.finish({ currentTarget: button, clientX: 15, clientY: 15, pointerId: 1 })

        // Still armed for the click that is about to fire...
        expect(guard.pointerDown).toBe(true)
        jest.runOnlyPendingTimers()
        // ...but not for any later one.
        expect(guard.pointerDown).toBe(false)
    })

    test('finish and cancel ignore events from a different pointer', () => {
        guard.prepare(down(), true)

        guard.finish({ currentTarget: button, clientX: 100, clientY: 100, pointerId: 2 })
        guard.cancel({ pointerId: 3 })

        expect(guard.pointerDown).toBe(true)
    })

    test('tolerates a currentTarget without pointer capture support', () => {
        expect(() => guard.prepare(down({ currentTarget: {} }), true)).not.toThrow()
        expect(guard.pointerDown).toBe(true)
    })
})
