/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import TopicsController from '../topics_controller'

describe('TopicsController#openTopicListPopup', () => {
    let application, controller
    const originalFetch = global.fetch

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
		jest.useRealTimers()
        global.fetch = originalFetch
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

    test('passes unread counts through to the topic-list popup', () => {
		controller.topics = [{ id: 2, name: 'Alpha', unread_count: 3 }]
		controller.archivedTopics = [{ id: 3, name: 'Zeta', unread_count: 5 }]
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => false) }, openForTopics: jest.fn() }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)
		const selectTopic = jest.spyOn(controller, 'selectTopic').mockImplementation(() => {})

		controller.openTopicListPopup({ currentTarget: btn })
		popup.openForTopics.mock.calls[0][2]({ id: 2 })

		expect(popup.openForTopics).toHaveBeenCalledWith(
			expect.objectContaining({
				topics: controller.topics,
				archivedTopics: controller.archivedTopics
			}),
			expect.any(Object),
			expect.any(Function),
			controller.element
		)
		expect(selectTopic).toHaveBeenCalledWith(2, { userInitiated: true })
    })

    test('reloads authoritative unread counts without incrementing the cached snapshot', async () => {
		jest.useFakeTimers()
		controller.topics = [{ id: 2, name: 'Alpha', unread_count: 2 }]
		controller.archivedTopics = [{ id: 3, name: 'Zeta', unread_count: 4 }]
		controller.refreshUnreadCounts = jest.fn().mockResolvedValue(undefined)

		controller.handleNewMessage({ detail: { topicId: '2' } })
		controller.handleNewMessage({ detail: { topicId: '2' } })

		expect(controller.topics[0].unread_count).toBe(2)
		expect(controller.refreshUnreadCounts).not.toHaveBeenCalled()
		await jest.advanceTimersByTimeAsync(250)
		expect(controller.refreshUnreadCounts).toHaveBeenCalledTimes(1)
    })

    test('leaves archived cached counts unchanged while scheduling a reload', async () => {
		jest.useFakeTimers()
		controller.archivedTopics = [{ id: 3, name: 'Zeta' }]
		controller.refreshUnreadCounts = jest.fn().mockResolvedValue(undefined)

		controller.handleNewMessage({ detail: { topicId: 3 } })

		expect(controller.archivedTopics[0].unread_count).toBeUndefined()
		await jest.advanceTimersByTimeAsync(250)
		expect(controller.refreshUnreadCounts).toHaveBeenCalledTimes(1)
    })

    test('queues one trailing reload while an unread reload is in flight', async () => {
		jest.useFakeTimers()
		let finishFirstLoad
		const firstLoad = new Promise(resolve => { finishFirstLoad = resolve })
		controller.refreshUnreadCounts = jest.fn()
			.mockReturnValueOnce(firstLoad)
			.mockResolvedValueOnce(undefined)

		controller.handleNewMessage({ detail: { topicId: '2' } })
		await jest.advanceTimersByTimeAsync(250)
		controller.handleNewMessage({ detail: { topicId: '2' } })
		controller.handleNewMessage({ detail: { topicId: '2' } })

		expect(controller.refreshUnreadCounts).toHaveBeenCalledTimes(1)
		finishFirstLoad()
		await Promise.resolve()
		await jest.advanceTimersByTimeAsync(250)
		expect(controller.refreshUnreadCounts).toHaveBeenCalledTimes(2)
	})

    test('reports an unread refresh failure without leaving it in flight', async () => {
		jest.useFakeTimers()
		const error = new Error('network failed')
		controller.refreshUnreadCounts = jest.fn().mockRejectedValue(error)
		const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})

		controller.handleNewMessage({ detail: { topicId: '2' } })
		await jest.advanceTimersByTimeAsync(250)

		expect(consoleError).toHaveBeenCalledWith('Failed to refresh topic unread counts', error)
		expect(controller._unreadCountRefreshInFlight).toBe(false)
	})

    test('retains topic snapshots while refreshing only authoritative unread counts', async () => {
		let finishRequest
		global.fetch = jest.fn(() => new Promise(resolve => { finishRequest = resolve }))
		controller.creativeIdValue = '42'
		controller.topics = [
			{ id: 2, name: 'Alpha', unread_count: 0 },
			{ id: 4, name: 'Beta', unread_count: 3 }
		]
		controller.archivedTopics = [{ id: 3, name: 'Zeta', unread_count: 1 }]
		controller.debounceSaveLastTopic = jest.fn()
		controller.renderTopics(controller.topics)
		const renderTopics = jest.spyOn(controller, 'renderTopics')

		const refreshing = controller.refreshUnreadCounts()
		expect(controller.topics).toEqual([
			{ id: 2, name: 'Alpha', unread_count: 0 },
			{ id: 4, name: 'Beta', unread_count: 3 }
		])
		finishRequest({
			ok: true,
			json: jest.fn().mockResolvedValue({
				topics: [
					{ id: 2, name: 'Changed on server', unread_count: 4 },
					{ id: 4, name: 'Also changed', unread_count: 0 }
				],
				archived_topics: [{ id: 3, name: 'Also changed', unread_count: 5 }]
			})
		})
		await refreshing

		expect(controller.topics).toEqual([
			{ id: 2, name: 'Alpha', unread_count: 4 },
			{ id: 4, name: 'Beta', unread_count: 0 }
		])
		expect(controller.archivedTopics).toEqual([{ id: 3, name: 'Zeta', unread_count: 5 }])
		expect(controller.listTarget.querySelector('[data-id="2"] .topic-unread-badge').textContent).toBe('4')
		expect(controller.listTarget.querySelector('[data-id="4"] .topic-unread-badge')).toBeNull()
		expect(renderTopics).not.toHaveBeenCalled()
		expect(controller.debounceSaveLastTopic).not.toHaveBeenCalled()
	})

	test('preserves an in-progress topic edit while refreshing unread counts', async () => {
		global.fetch = jest.fn().mockResolvedValue({
			ok: true,
			json: jest.fn().mockResolvedValue({
				topics: [{ id: 2, name: 'Alpha', unread_count: 4 }],
				archived_topics: []
			})
		})
		controller.creativeIdValue = '42'
		controller.topics = [{ id: 2, name: 'Alpha', unread_count: 1 }]
		controller.canManageTopics = true
		controller.renderTopics(controller.topics, true)
		const topicEl = controller.listTarget.querySelector('[data-id="2"]')
		controller.showEditInput(topicEl, '2')
		const input = topicEl.querySelector('.topic-edit-input')
		input.value = 'Draft topic name'

		await controller.refreshUnreadCounts()

		expect(topicEl.querySelector('.topic-edit-input')).toBe(input)
		expect(input.value).toBe('Draft topic name')
		controller.cancelEdit({ target: input })
		expect(topicEl.querySelector('.topic-unread-badge').textContent).toBe('4')
	})

	test('discards an in-flight unread response after disconnect', async () => {
		let finishRequest
		global.fetch = jest.fn(() => new Promise(resolve => { finishRequest = resolve }))
		controller.creativeIdValue = '42'
		controller.topics = [{ id: 2, name: 'Alpha', unread_count: 1 }]
		const refreshPopup = jest.spyOn(controller, 'refreshOpenTopicListPopup')
		const refreshing = controller.refreshUnreadCounts()

		controller.disconnect()
		finishRequest({
			ok: true,
			json: jest.fn().mockResolvedValue({
				topics: [{ id: 2, name: 'Alpha', unread_count: 5 }],
				archived_topics: []
			})
		})
		await refreshing

		expect(controller.topics[0].unread_count).toBe(1)
		expect(refreshPopup).not.toHaveBeenCalled()
	})

    test('clears cached and rendered unread counts when a topic is opened', () => {
		controller.topics = [{ id: 2, name: 'Alpha', unread_count: 3 }]
		controller.renderTopics(controller.topics)

		controller.clearNewMessageBadge('2')

		expect(controller.topics[0].unread_count).toBe(0)
		expect(controller.listTarget.querySelector('[data-id="2"] .topic-unread-badge')).toBeNull()
    })

    test('cancels a scheduled unread reload when the popup closes', async () => {
		jest.useFakeTimers()
		controller.creativeIdValue = '42'
		controller.refreshUnreadCounts = jest.fn().mockResolvedValue(undefined)
		controller.handleNewMessage({ detail: { topicId: '2' } })

		controller.onPopupClosed()
		await jest.advanceTimersByTimeAsync(250)

		expect(controller.refreshUnreadCounts).not.toHaveBeenCalled()
    })

    test('lets other popups process the pointer event and consumes the matching click when open', () => {
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => true) }, close: jest.fn(), openForTopics: jest.fn() }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

		controller.prepareTopicListToggle({ isPrimary: true, button: 0, pointerId: 1, currentTarget: { setPointerCapture: jest.fn() } })
		controller.openTopicListPopup({ currentTarget: btn })

		expect(popup.close).not.toHaveBeenCalled()
		expect(popup.openForTopics).not.toHaveBeenCalled()
    })

    test('keeps the toggle pending through a touch-generated mouse event', () => {
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn().mockReturnValueOnce(true).mockReturnValue(false) }, close: jest.fn(), openForTopics: jest.fn() }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

		controller.prepareTopicListToggle({ isPrimary: true, button: 0, pointerId: 1, currentTarget: { setPointerCapture: jest.fn() } }) // pointerdown while the popup is open
		controller.openTopicListPopup({ currentTarget: btn })

		expect(popup.openForTopics).not.toHaveBeenCalled()
    })

    test('clears the pending toggle when a primary pointer is canceled or released outside the button', () => {
		const btn = controller.topicListButtonTarget
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => true) } }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)
		jest.spyOn(btn, 'getBoundingClientRect').mockReturnValue({ left: 10, right: 20, top: 10, bottom: 20 })

		controller.prepareTopicListToggle({ isPrimary: true, button: 0, pointerId: 1, currentTarget: { setPointerCapture: jest.fn() } })
		controller.cancelTopicListToggle({ pointerId: 1 })
		expect(controller.topicListTogglePointerDown).toBe(false)

		controller.prepareTopicListToggle({ isPrimary: true, button: 0, pointerId: 2, currentTarget: { setPointerCapture: jest.fn() } })
		controller.finishTopicListToggle({ currentTarget: btn, clientX: 25, clientY: 15, pointerId: 2 })
		expect(controller.topicListTogglePointerDown).toBe(false)
	})

	test('clears a completed pointer gesture that does not dispatch click', () => {
		jest.useFakeTimers()
		const modal = document.createElement('div')
		modal.id = 'topic-list-modal'
		controller.element.appendChild(modal)
		const popup = { popup: { isOpen: jest.fn(() => true) } }
		jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)
		const btn = controller.topicListButtonTarget
		jest.spyOn(btn, 'getBoundingClientRect').mockReturnValue({ left: 10, right: 20, top: 10, bottom: 20 })

		controller.prepareTopicListToggle({ isPrimary: true, button: 0, pointerId: 1, currentTarget: { setPointerCapture: jest.fn() } })
		controller.finishTopicListToggle({ currentTarget: btn, clientX: 15, clientY: 15, pointerId: 1 })
		jest.runOnlyPendingTimers()

		expect(controller.topicListTogglePointerDown).toBe(false)
		jest.useRealTimers()
	})

	test('ignores non-primary pointer events and stale pointer cleanup', () => {
		controller.prepareTopicListToggle({ isPrimary: false, button: 0, pointerId: 1 })
		controller.prepareTopicListToggle({ isPrimary: true, button: 2, pointerId: 2 })
		controller.cancelTopicListToggle({ pointerId: 3 })

		expect(controller.topicListTogglePointerDown).toBeUndefined()
	})

    test('removes the topic-list close listener when disconnecting', () => {
		const removeEventListener = jest.spyOn(controller.element, 'removeEventListener')

		controller.disconnect()

		expect(removeEventListener).toHaveBeenCalledWith('topic-list:close', controller.handleTopicListClose)
    })
})
