/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import TopicsController from '../topics_controller'

describe('TopicsController#openTopicListPopup', () => {
    let application, controller

    beforeEach(() => {
        global.requestAnimationFrame = (fn) => { fn(); return 0 }
        document.body.innerHTML = `
          <div id="comments-popup" data-controller="comments--topics"
               data-topic-main-text="All Messages"
               data-topic-search-placeholder-text="Search topics...">
            <div data-comments--topics-target="list"></div>
			<button data-comments--topics-target="topicListButton" aria-expanded="false"></button>
          </div>
        `
        application = Application.start()
        application.register('comments--topics', TopicsController)
        return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
            controller = application.getControllerForElementAndIdentifier(
                document.getElementById('comments-popup'), 'comments--topics'
            )
            controller.topics = [{ id: 2, name: 'Alpha' }]
            controller.archivedTopics = [{ id: 3, name: 'Zeta' }]
            controller.mainTopicId = null
        })
    })

    afterEach(() => {
        document.body.innerHTML = ''
        application.stop()
        jest.clearAllMocks()
    })

    test('creates the topic-list modal with the required targets', () => {
        const btn = document.createElement('button')
        document.body.appendChild(btn)
        controller.openTopicListPopup({ currentTarget: btn })

        const modal = document.getElementById('topic-list-modal')
        expect(modal).not.toBeNull()
        expect(modal.dataset.controller).toBe('topic-list')
        expect(modal.querySelector('[data-topic-list-target="input"]')).not.toBeNull()
        expect(modal.querySelector('[data-topic-list-target="list"]')).not.toBeNull()
        expect(modal.querySelector('[data-topic-list-target="close"]')).not.toBeNull()
        expect(modal.querySelector('input').placeholder).toBe('Search topics...')
    })

    test('appends the modal inside the chat box so it is caged within it', () => {
        const btn = document.createElement('button')
        document.body.appendChild(btn)
        controller.openTopicListPopup({ currentTarget: btn })

        const modal = document.getElementById('topic-list-modal')
        // Bounded to the chat popup, not body-level.
        expect(modal.parentElement).toBe(document.getElementById('comments-popup'))
    })

    test('toggles an existing open popup closed and updates the button state', () => {
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		modal.style.display = 'block'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => true) }, close: jest.fn() }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

		controller.openTopicListPopup({ currentTarget: btn })

		expect(popup.close).toHaveBeenCalled()
		expect(btn.getAttribute('aria-expanded')).toBe('false')
    })

    test('sets the button state while opening and clears it when the popup closes', () => {
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => false) }, openForTopics: jest.fn() }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

		controller.openTopicListPopup({ currentTarget: btn })

		expect(popup.openForTopics).toHaveBeenCalled()
		expect(btn.getAttribute('aria-expanded')).toBe('true')

		modal.dispatchEvent(new CustomEvent('topic-list:close', { bubbles: true }))
		expect(btn.getAttribute('aria-expanded')).toBe('false')
    })

    test('lets other popups process the pointer event and consumes the matching click when open', () => {
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => true) }, close: jest.fn(), openForTopics: jest.fn() }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

		controller.prepareTopicListToggle()
		controller.openTopicListPopup({ currentTarget: btn })

		expect(popup.close).not.toHaveBeenCalled()
		expect(popup.openForTopics).not.toHaveBeenCalled()
    })

    test('removes the topic-list close listener when disconnecting', () => {
		const removeEventListener = jest.spyOn(controller.element, 'removeEventListener')

		controller.disconnect()

		expect(removeEventListener).toHaveBeenCalledWith('topic-list:close', controller.handleTopicListClose)
    })
})
