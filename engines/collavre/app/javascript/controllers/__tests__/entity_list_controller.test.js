/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import EntityListController from '../entity_list_controller'

describe('EntityListController', () => {
    let application, controller

    const mount = () => {
        document.body.innerHTML = `
          <div id="entity-list-modal" class="common-popup" data-controller="entity-list">
            <button data-entity-list-target="close">×</button>
            <input data-entity-list-target="input">
            <ul class="common-popup-list" data-popup-list data-entity-list-target="list"></ul>
          </div>
        `
        application = Application.start()
        application.register('entity-list', EntityListController)
        return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
            controller = application.getControllerForElementAndIdentifier(
                document.getElementById('entity-list-modal'), 'entity-list'
            )
        })
    }

    const RECT = { top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0 }
    const ITEMS = [
        { id: 'self', label: 'This creative', iconKey: 'pin' },
        { id: 1, label: 'Alpha', iconKey: 'context' },
        { id: 2, label: 'Beta', iconKey: 'context', muted: true, badge: 'Inherited' }
    ]

    const items = () => Array.from(document.querySelectorAll('#entity-list-modal li.common-popup-item'))

    beforeEach(() => {
        global.requestAnimationFrame = (fn) => { fn(); return 0 }
        return mount()
    })

    afterEach(() => {
        document.body.innerHTML = ''
        application.stop()
        jest.clearAllMocks()
    })

    test('renders the items it is given, in order', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        expect(items().map((li) => li.textContent.trim())).toEqual([
            'This creative', 'Alpha', 'BetaInherited'
        ])
    })

    test('marks muted items with the distinguishing class', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        expect(items()[1].querySelector('.entity-list-item--muted')).toBeNull()
        expect(items()[2].querySelector('.entity-list-item--muted')).not.toBeNull()
    })

    test('renders an avatar when the item carries one', () => {
        controller.openForItems([{ id: 9, label: 'Ada', avatarUrl: '/avatars/9.png' }], RECT, () => {})
        expect(items()[0].querySelector('.entity-list-item-avatar').getAttribute('src')).toBe('/avatars/9.png')
    })

    test('filters by label substring', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        controller.inputTarget.value = 'alp'
        controller._onInput()
        expect(items().map((li) => li.textContent.trim())).toEqual(['Alpha'])

        controller.inputTarget.value = 'nothing'
        controller._onInput()
        expect(items()).toHaveLength(0)
    })

    test('updateItems keeps the current search and the active row', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        controller.popup.setActiveIndex(1)

        controller.updateItems([...ITEMS, { id: 3, label: 'Gamma' }])

        expect(controller.inputTarget.value).toBe('')
        expect(controller.popup.activeIndex).toBe(1)
        expect(items()).toHaveLength(4)
    })

    test('escapes labels, badges and avatar urls', () => {
        controller.openForItems([{
            id: 1,
            label: '<img src=x onerror=alert(1)>',
            badge: '<b>bad</b>',
            avatarUrl: '" onerror="alert(1)'
        }], RECT, () => {})

        expect(controller.listTarget.querySelectorAll('img')).toHaveLength(1) // only the avatar
        expect(controller.listTarget.querySelector('b')).toBeNull()
        expect(controller.listTarget.textContent).toContain('<img src=x onerror=alert(1)>')
        expect(controller.listTarget.querySelector('img').getAttribute('onerror')).toBeNull()
    })

    test('unknown icon keys render nothing rather than raw markup', () => {
        controller.openForItems([{ id: 1, label: 'Alpha', iconKey: '<script>x</script>' }], RECT, () => {})
        expect(controller.listTarget.querySelector('svg')).toBeNull()
        expect(controller.listTarget.querySelector('script')).toBeNull()
    })

    test('select invokes the callback and closes by default', () => {
        const cb = jest.fn()
        controller.openForItems(ITEMS, RECT, cb)
        controller.select(ITEMS[1])
        expect(cb).toHaveBeenCalledWith(ITEMS[1])
        expect(controller.popup.isOpen()).toBe(false)
    })

    test('select keeps the popup open when the callback returns true', () => {
        const cb = jest.fn(() => true)
        controller.openForItems(ITEMS, RECT, cb)
        controller.select(ITEMS[1])
        expect(cb).toHaveBeenCalled()
        expect(controller.popup.isOpen()).toBe(true)
    })

    test('Enter selects the active row', () => {
        const cb = jest.fn()
        controller.openForItems(ITEMS, RECT, cb)
        controller.popup.setActiveIndex(2)
        controller.handleInputKeydown({ key: 'Enter', preventDefault: jest.fn() })
        expect(cb).toHaveBeenCalledWith(expect.objectContaining({ id: 2 }))
    })

    test('Escape closes the popup', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        controller.handleInputKeydown({ key: 'Escape', preventDefault: jest.fn() })
        expect(controller.popup.isOpen()).toBe(false)
    })

    describe('search-box focus', () => {
        const originalInnerWidth = window.innerWidth
        const setViewportWidth = (value) =>
            Object.defineProperty(window, 'innerWidth', { value, configurable: true })

        afterEach(() => setViewportWidth(originalInnerWidth))

        test('focuses the search box on desktop widths', () => {
            setViewportWidth(1024)
            controller.openForItems(ITEMS, RECT, () => {})
            expect(document.activeElement).toBe(controller.inputTarget)
        })

        test('does not focus the search box on mobile widths', () => {
            setViewportWidth(390)
            const chatInput = document.createElement('textarea')
            document.body.appendChild(chatInput)
            chatInput.focus()

            controller.openForItems(ITEMS, RECT, () => {})

            expect(document.activeElement).toBe(document.body)
        })
    })
})
