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
          <div id="entity-list-modal" class="common-popup" data-controller="entity-list" data-close-label="Close">
            <button data-entity-list-target="close">×</button>
            <input data-entity-list-target="input" placeholder="Search entities...">
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

    test('exposes combobox, listbox, option, and active-row semantics', () => {
        controller.openForItems(ITEMS.map((item, index) => ({ ...item, selected: index === 1 })), RECT, () => {})
        const rows = items()

        expect(controller.inputTarget.getAttribute('role')).toBe('combobox')
        expect(controller.inputTarget.getAttribute('aria-label')).toBe('Search entities...')
        expect(controller.inputTarget.getAttribute('aria-expanded')).toBe('true')
        expect(controller.inputTarget.getAttribute('aria-controls')).toBe(controller.listTarget.id)
        expect(controller.listTarget.getAttribute('role')).toBe('listbox')
        expect(controller.listTarget.getAttribute('aria-multiselectable')).toBe('true')
        expect(rows.every((row) => row.getAttribute('role') === 'option')).toBe(true)
        expect(controller.inputTarget.getAttribute('aria-activedescendant')).toBe(rows[0].id)
        expect(rows.map((row) => row.getAttribute('aria-selected'))).toEqual(['false', 'true', 'false'])

        controller.handleInputKeydown({ key: 'ArrowDown', preventDefault: jest.fn() })

        expect(controller.inputTarget.getAttribute('aria-activedescendant')).toBe(rows[1].id)
        expect(rows.map((row) => row.getAttribute('aria-selected'))).toEqual(['false', 'true', 'false'])
    })

    test('removes multiselect semantics when items do not expose selection state', () => {
        controller.openForItems([{ id: 1, label: 'Alpha', selected: true }], RECT, () => {})
        controller.updateItems(ITEMS)

        expect(controller.listTarget.hasAttribute('aria-multiselectable')).toBe(false)
    })

    test('uses stable option ids across filtering', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        const alphaId = items()[1].id
        controller.inputTarget.value = 'alpha'
        controller._onInput()

        expect(items()[0].id).toBe(alphaId)
    })

    test('labels the close button and clears expanded state on close', () => {
        expect(controller.closeTarget.getAttribute('aria-label')).toBe('Close')
        controller.openForItems(ITEMS, RECT, () => {})

        controller.close()

        expect(controller.inputTarget.getAttribute('aria-expanded')).toBe('false')
        expect(controller.inputTarget.hasAttribute('aria-activedescendant')).toBe(false)
    })

    test('marks muted items with the distinguishing class', () => {
        controller.openForItems(ITEMS, RECT, () => {})
        expect(items()[1].querySelector('.entity-list-item--muted')).toBeNull()
        expect(items()[2].querySelector('.entity-list-item--muted')).not.toBeNull()
    })

    test('exposes localized item status text to assistive technology', () => {
        controller.openForItems([{ id: 1, label: 'Ada', muted: true, statusLabel: 'Offline' }], RECT, () => {})

        expect(items()[0].querySelector('.entity-list-item-status').textContent).toBe('Offline')
    })

    test('marks non-actionable options disabled and does not select them', () => {
        const cb = jest.fn()
        controller.openForItems([{ id: 1, label: 'Read only', actionable: false }], RECT, cb)

        expect(items()[0].getAttribute('aria-disabled')).toBe('true')
        controller.select(controller.popup.items[0])
        expect(cb).not.toHaveBeenCalled()
        expect(controller.popup.isOpen()).toBe(true)
    })

    test('renders an avatar when the item carries one', () => {
        controller.openForItems([{ id: 9, label: 'Ada', avatarUrl: '/avatars/9.png' }], RECT, () => {})
        expect(items()[0].querySelector('.entity-list-item-avatar').getAttribute('src')).toBe('/avatars/9.png')
    })

    test('filters by label substring', () => {
        const reposition = jest.spyOn(controller.popup, 'reposition')
        controller.openForItems(ITEMS, RECT, () => {})
        controller.inputTarget.value = 'alp'
        controller._onInput()
        expect(items().map((li) => li.textContent.trim())).toEqual(['Alpha'])

        controller.inputTarget.value = 'nothing'
        controller._onInput()
        expect(items()).toHaveLength(0)
        expect(reposition).toHaveBeenCalled()
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

    test('Escape closes the popup when filtering leaves no items', () => {
	controller.openForItems(ITEMS, RECT, () => {})
	controller.inputTarget.value = 'nothing'
	controller._onInput()

	controller.handleInputKeydown({ key: 'Escape', preventDefault: jest.fn() })

	expect(controller.popup.items).toEqual([])
	expect(controller.popup.isOpen()).toBe(false)
    })

    test('Tab closes without selecting or preventing focus traversal', () => {
        const cb = jest.fn()
        const preventDefault = jest.fn()
        controller.openForItems(ITEMS, RECT, cb)

        controller.handleInputKeydown({ key: 'Tab', preventDefault })

        expect(cb).not.toHaveBeenCalled()
        expect(preventDefault).not.toHaveBeenCalled()
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

        test('focuses the close button instead of the search box on mobile widths', () => {
            setViewportWidth(390)
            const chatInput = document.createElement('textarea')
            document.body.appendChild(chatInput)
            chatInput.focus()

            controller.openForItems(ITEMS, RECT, () => {})

            expect(document.activeElement).toBe(controller.closeTarget)
        })
    })
})
