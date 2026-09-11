/**
 * @jest-environment jsdom
 */
import { caretAnchor } from '../caret_position'

// caretAnchor is what a caret-anchored popup hands to CommonPopup.showAt in
// place of a rect: the caret is not an element, so the only way placement can
// re-measure it later is to re-derive it from the input each time.
describe('caretAnchor', () => {
    let textarea

    // jsdom measures every element as a zeroed rect, so the mirror-div path in
    // getCaretClientRect cannot produce distinguishable coordinates. Dropping
    // selectionStart takes the documented fallback branch instead, where the
    // rect is the input's own and therefore stubbable.
    const useInputRectFallback = () => {
        Object.defineProperty(textarea, 'selectionStart', { value: null, configurable: true })
    }

    beforeEach(() => {
        textarea = document.createElement('textarea')
        textarea.value = 'hello'
        document.body.appendChild(textarea)
    })

    afterEach(() => {
        document.body.innerHTML = ''
    })

    test('re-derives the rect on every call, so a moved input moves the anchor', () => {
        useInputRectFallback()
        const anchor = caretAnchor(textarea)

        textarea.getBoundingClientRect = () => ({ left: 10, top: 500, bottom: 540 })
        const before = anchor()
        // The keyboard opens and the composer is lifted clear of it.
        textarea.getBoundingClientRect = () => ({ left: 10, top: 200, bottom: 240 })
        const after = anchor()

        expect(before.top).toBe(500)
        expect(after.top).toBe(200)
    })

    test('falls back to the input rect when the caret cannot be located', () => {
        const inputRect = { left: 10, top: 200, bottom: 240 }
        textarea.getBoundingClientRect = () => inputRect
        useInputRectFallback()

        expect(caretAnchor(textarea)()).toBe(inputRect)
    })

    test('measures the caret, not the whole input, when the caret is locatable', () => {
        const inputRect = { left: 10, top: 200, bottom: 240 }
        textarea.getBoundingClientRect = () => inputRect
        textarea.setSelectionRange(3, 3)

        const rect = caretAnchor(textarea)()

        expect(rect).not.toBe(inputRect)
        expect(rect).not.toBeNull()
    })

    test('returns nothing once the input has left the document', () => {
        const anchor = caretAnchor(textarea)
        textarea.remove()

        // A detached input measures as all zeros, which would pin the popup to
        // the top-left corner; CommonPopup keeps its last rect on a null.
        expect(anchor()).toBeNull()
    })

    test('returns nothing when there is no input at all', () => {
        expect(caretAnchor(null)()).toBeNull()
    })
})
