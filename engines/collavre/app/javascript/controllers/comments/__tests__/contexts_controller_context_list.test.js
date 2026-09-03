/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import ContextsController from '../contexts_controller'
import EntityListController from '../../entity_list_controller'

describe('CommentsContextsController — pinned add/list buttons', () => {
    let application, controller

    beforeEach(async () => {
        global.requestAnimationFrame = (fn) => { fn(); return 0 }
        global.fetch = jest.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve({}) }))

        document.body.innerHTML = `
          <div id="comments-popup" data-controller="comments--contexts"
               data-creative-id="42"
               data-context-search-placeholder-text="Search contexts...">
            <h3 id="comments-popup-title">Current creative</h3>
            <button data-comments--contexts-target="toggleButton"></button>
            <div class="comment-contexts-bar" data-comments--contexts-target="bar" style="display:none;">
              <div data-comments--contexts-target="list" class="comment-contexts-list"
                   data-inherited-label="Inherited from parent"></div>
              <button data-comments--contexts-target="addButton" class="add-context-btn" style="display:none;">+</button>
              <button data-comments--contexts-target="listButton" class="bar-list-btn" aria-expanded="false"></button>
            </div>
          </div>
        `
        application = Application.start()
        application.register('comments--contexts', ContextsController)
        application.register('entity-list', EntityListController)
        await new Promise((resolve) => setTimeout(resolve, 0))
        controller = application.getControllerForElementAndIdentifier(
            document.getElementById('comments-popup'), 'comments--contexts'
        )
    })

    afterEach(() => {
        document.body.innerHTML = ''
        application.stop()
        jest.restoreAllMocks()
    })

    const anchorEvent = () => ({ currentTarget: controller.listButtonTarget })

    test('renders no add button inside the scrolling chip list', () => {
        controller.canManage = true
        controller.contexts = []
        controller.renderContexts()

        expect(controller.listTarget.querySelector('.add-context-btn')).toBeNull()
    })

    test('shows the pinned add button only when the user can manage contexts', () => {
        controller.canManage = true
        controller.renderContexts()
        expect(controller.addButtonTarget.style.display).toBe('')

        controller.canManage = false
        controller.renderContexts()
        expect(controller.addButtonTarget.style.display).toBe('none')
    })

    test('toggling visibility hides the whole bar, not just the chip list', () => {
        controller.toggleVisibility()
        expect(controller.barTarget.style.display).toBe('')
        expect(controller.listTarget.style.display).toBe('')

        controller.toggleVisibility()
        expect(controller.barTarget.style.display).toBe('none')
    })

    test('anchors the link-creative modal to the pinned add button', () => {
        const open = jest.fn()
        window.Stimulus = { getControllerForElementAndIdentifier: () => ({ open }) }
        document.body.insertAdjacentHTML('beforeend', '<div data-controller="link-creative"></div>')

        controller.addContext()

        expect(open).toHaveBeenCalled()
        delete window.Stimulus
    })

    test('builds list items: self first, then contexts with disabled/inherited state', () => {
        controller._selfContextDisabled = true
        controller.contexts = [
            { id: 1, description: 'Alpha', disabled: false, inherited: false },
            { id: 2, description: 'Beta', disabled: true, inherited: true }
        ]

        expect(controller.contextListItems()).toEqual([
            { id: 'self', label: 'Current creative', iconKey: 'pin', muted: true },
            { id: 1, label: 'Alpha', iconKey: 'context', muted: false, badge: null },
            { id: 2, label: 'Beta', iconKey: 'context', muted: true, badge: 'Inherited from parent' }
        ])
    })

    test('creates the entity-list modal caged inside the chat box', () => {
        controller.contexts = []
        controller.openContextListPopup(anchorEvent())

        const modal = document.getElementById('context-list-modal')
        expect(modal).not.toBeNull()
        expect(modal.dataset.controller).toBe('entity-list')
        expect(modal.parentElement).toBe(controller.element)
        expect(modal.querySelector('[data-entity-list-target="input"]').placeholder).toBe('Search contexts...')
        expect(modal.querySelector('[data-entity-list-target="list"]')).not.toBeNull()
        expect(modal.querySelector('[data-entity-list-target="close"]')).not.toBeNull()
    })

    test('toggles an open popup closed and clears the button state', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.openContextListPopup(anchorEvent())

        expect(popup.close).toHaveBeenCalled()
        expect(controller.listButtonTarget.getAttribute('aria-expanded')).toBe('false')
    })

    test('marks the button expanded while open and clears it on close', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => false }, openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.openContextListPopup(anchorEvent())
        expect(popup.openForItems).toHaveBeenCalledWith(
            expect.any(Array), expect.any(Object), expect.any(Function), controller.element
        )
        expect(controller.listButtonTarget.getAttribute('aria-expanded')).toBe('true')

        modal.dispatchEvent(new CustomEvent('entity-list:close', { bubbles: true }))
        expect(controller.listButtonTarget.getAttribute('aria-expanded')).toBe('false')
    })

    test('ignores close events from another popup sharing the entity-list controller', () => {
        controller.setContextListButtonExpanded(true)
        const other = document.createElement('div')
        other.id = 'participant-list-modal'
        controller.element.appendChild(other)

        other.dispatchEvent(new CustomEvent('entity-list:close', { bubbles: true }))

        expect(controller.listButtonTarget.getAttribute('aria-expanded')).toBe('true')
    })

    test('a pointerdown that closed the popup swallows the following click', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn(), openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        // The popup's own outside-click handler closes it on pointerdown.
        controller.prepareContextListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.listButtonTarget
        })
        controller.openContextListPopup(anchorEvent())

        expect(popup.openForItems).not.toHaveBeenCalled()
    })

    test('a pointerdown with no popup open lets the click through', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => false }, openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.prepareContextListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.listButtonTarget
        })
        controller.openContextListPopup(anchorEvent())

        expect(popup.openForItems).toHaveBeenCalled()
    })

    test('releasing the pointer outside the button re-arms the click', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn(), openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)
        jest.spyOn(controller.listButtonTarget, 'getBoundingClientRect')
            .mockReturnValue({ left: 10, right: 20, top: 10, bottom: 20 })

        controller.prepareContextListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.listButtonTarget
        })
        controller.finishContextListToggle({
            currentTarget: controller.listButtonTarget, clientX: 99, clientY: 99, pointerId: 1
        })
        controller.openContextListPopup(anchorEvent())

        expect(popup.close).toHaveBeenCalled()
    })

    test('cancelling the gesture lets the next click through', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.prepareContextListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.listButtonTarget
        })
        controller.cancelContextListToggle({ pointerId: 1 })
        controller.openContextListPopup(anchorEvent())

        expect(popup.close).toHaveBeenCalled()
    })

    test('selecting a context toggles it and keeps the popup open', () => {
        controller.contexts = [{ id: 1, description: 'Alpha', disabled: false, inherited: false }]

        const keepOpen = controller.selectContextListItem({ id: 1 })

        expect(keepOpen).toBe(true)
        expect(controller.contexts[0].disabled).toBe(true)
    })

    test('selecting the self entry toggles the self context', () => {
        controller._selfContextDisabled = false

        expect(controller.selectContextListItem({ id: 'self' })).toBe(true)
        expect(controller.selfContextDisabled).toBe(true)
    })

    test('re-rendering refreshes an open popup so toggles are reflected', () => {
        const modal = document.createElement('div')
        modal.id = 'context-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, updateItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.contexts = [{ id: 1, description: 'Alpha', disabled: false, inherited: false }]
        controller.renderContexts()

        expect(popup.updateItems).toHaveBeenCalledWith(
            expect.arrayContaining([expect.objectContaining({ id: 1, label: 'Alpha' })])
        )
    })
})
