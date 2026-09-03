
/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import CommentsPopupController from '../popup_controller'
import chatDrafts from '../../../lib/chat_drafts'

describe('CommentsPopupController', () => {
    let application
    let container
    let controller

    beforeEach(() => {
        window.localStorage.clear()
        document.body.dataset.currentUserId = '9'
        container = document.createElement('div')
        container.innerHTML = `
      <div id="comments-popup" data-controller="comments--popup" data-fullscreen-url-template="/creatives/__CREATIVE_ID__/comments/fullscreen" style="width: 300px; height: 400px; position: absolute;">
        <h3 data-comments--popup-target="title">Title</h3>
        <div data-comments--popup-target="list">List</div>
        <a data-comments--popup-target="fullscreenLink" href="#"></a>
        <button data-comments--popup-target="closeButton">
          <span data-comments--popup-target="closeIcon" aria-hidden="true"><svg data-icon="close"></svg></span>
          <span data-comments--popup-target="expandDockedIcon" aria-hidden="true" style="display:none;"><svg data-icon="expand"></svg></span>
        </button>
        <div data-comments--popup-target="leftHandle"></div>
        <div data-comments--popup-target="rightHandle"></div>
      </div>
      <button id="trigger-btn" data-creative-id="123" data-can-comment="true">Open</button>
      <form id="logout-form" action="/session"></form>
      <form id="mounted-logout-form" action="/collavre/session"></form>
    `
        document.body.appendChild(container)

        application = Application.start()
        application.register('comments--popup', CommentsPopupController)

        // Manual controller access for testing internals if needed, 
        // though usually better to test via DOM/events.
        // Waiting for connection:
        return new Promise(resolve => setTimeout(resolve, 0)).then(() => {
            const element = document.getElementById('comments-popup')
            controller = application.getControllerForElementAndIdentifier(element, 'comments--popup')
        })
    })

    afterEach(() => {
        document.body.innerHTML = ''
        delete document.body.dataset.currentUserId
        application.stop()
    })

    test('close in fullscreen exits fullscreen state and cleans up body class', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')

        // Open popup
        controller.open(triggerBtn)

        // Simulate entering fullscreen
        popup.dataset.fullscreen = 'true'
        popup.dataset.creativeId = '123'
        document.body.classList.add('chat-fullscreen')

        // Close popup
        controller.close()

        expect(popup.style.display).toBe('none')
        expect(popup.dataset.fullscreen).toBe('false')
        expect(document.body.classList.contains('chat-fullscreen')).toBe(false)
    })

    test('scrolls to the active topic only once after exiting fullscreen', () => {
        jest.useFakeTimers()
        const popup = document.getElementById('comments-popup')
        const scrollToActiveTopic = jest.fn()
        Object.defineProperty(controller, 'topicsController', {
            configurable: true,
            value: {
                clearOverrideTopicId: jest.fn(),
                onPopupClosed: jest.fn(),
                onPopupOpened: jest.fn(),
                scrollToActiveTopic,
            },
        })
        popup.dataset.fullscreen = 'true'
        popup.dataset.creativeId = '123'
        controller._savedStyles = {
            top: '10px',
            right: '20px',
            left: '',
            width: '300px',
            height: '400px',
        }
        const addEventListener = jest.spyOn(popup, 'addEventListener')

        try {
            controller.toggleFullscreen()
            const transitionCleanup = addEventListener.mock.calls.find(
                ([type]) => type === 'transitionend',
            )[1]
            transitionCleanup()
            transitionCleanup()
            jest.advanceTimersByTime(300)

            expect(scrollToActiveTopic).toHaveBeenCalledTimes(1)
            expect(jest.getTimerCount()).toBe(0)
        } finally {
            addEventListener.mockRestore()
            delete controller.topicsController
            jest.useRealTimers()
        }
    })

    test('clears resized dataset attribute on close', () => {
        const triggerBtn = document.getElementById('trigger-btn')
        const popup = document.getElementById('comments-popup')

        // Open popup
        controller.open(triggerBtn)
        expect(popup.style.display).not.toBe('none')

        // Simulate resize start
        const leftHandle = popup.querySelector('[data-comments--popup-target="leftHandle"]')
        leftHandle.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: 100, clientY: 100 }))

        // Moving mouse to resize
        window.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 90, clientY: 100 }))

        expect(popup.dataset.resized).toBe('true')

        // Close popup
        controller.close()

        expect(popup.style.display).toBe('none')
        expect(popup.dataset.resized).toBeUndefined()
    })

    test('keeps the mobile chat open while scrolling down inside the topic-list popup', () => {
		const popup = document.getElementById('comments-popup')
		const topicListModal = document.createElement('div')
		const topicListItem = document.createElement('li')
		topicListModal.id = 'topic-list-modal'
		topicListModal.className = 'common-popup'
		topicListModal.appendChild(topicListItem)
		popup.appendChild(topicListModal)
		jest.spyOn(controller, 'isMobile').mockReturnValue(true)
		const close = jest.spyOn(controller, 'close')

		controller.handleTouchStart({
			target: topicListItem,
			touches: [{ clientY: 100 }]
		})
		controller.handleTouchEnd({ changedTouches: [{ clientY: 180 }] })

		expect(close).not.toHaveBeenCalled()
		expect(controller.touchStartY).toBeNull()
    })

	test.each(['context-list-modal', 'participant-list-modal'])(
		'keeps the mobile chat open while scrolling down inside %s',
		(modalId) => {
			const popup = document.getElementById('comments-popup')
			const modal = document.createElement('div')
			const item = document.createElement('li')
			modal.id = modalId
			modal.className = 'common-popup'
			modal.appendChild(item)
			popup.appendChild(modal)
			jest.spyOn(controller, 'isMobile').mockReturnValue(true)
			const close = jest.spyOn(controller, 'close')

			controller.handleTouchStart({
				target: item,
				touches: [{ clientY: 100 }]
			})
			controller.handleTouchEnd({ changedTouches: [{ clientY: 180 }] })

			expect(close).not.toHaveBeenCalled()
			expect(controller.touchStartY).toBeNull()
		}
	)

    test('inherits auto-focus preference from trigger button', async () => {
        const triggerBtn = document.getElementById('trigger-btn')
        const popup = document.getElementById('comments-popup')

        triggerBtn.dataset.autoFocusOnOpen = 'false'

        await controller.open(triggerBtn)

        expect(popup.dataset.autoFocusOnOpen).toBe('false')
    })

    test('openForCreative resets auto-focus preference to default', async () => {
        const triggerBtn = document.getElementById('trigger-btn')
        const popup = document.getElementById('comments-popup')

        triggerBtn.dataset.autoFocusOnOpen = 'false'
        await controller.open(triggerBtn)
        expect(popup.dataset.autoFocusOnOpen).toBe('false')

        await controller.openForCreative()

        expect(popup.dataset.autoFocusOnOpen).toBe('true')
    })

    test('docked chat opens by default and close collapses instead of hiding it', async () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.collapseDockedLabel = 'Collapse chat'
        popup.dataset.expandDockedLabel = 'Expand chat'

        controller.enterDockedMode()
        controller.close()

        expect(popup.style.display).toBe('flex')
        expect(popup.classList.contains('docked-collapsed')).toBe(true)
        expect(controller.closeButtonTarget.getAttribute('aria-label')).toBe('Expand chat')
    })

    test('docked close button shows the close asset while expanded and a chevron when collapsed', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.collapseDockedLabel = 'Collapse chat'
        popup.dataset.expandDockedLabel = 'Expand chat'

        controller.enterDockedMode()
        controller.syncDockedUI()
        expect(controller.closeIconTarget.style.display).toBe('')
        expect(controller.expandDockedIconTarget.style.display).toBe('none')
        expect(controller.closeIconTarget.getAttribute('aria-hidden')).toBe('true')
        expect(controller.closeIconTarget.querySelector('[data-icon="close"]')).not.toBeNull()
        expect(controller.closeButtonTarget.getAttribute('aria-label')).toBe('Collapse chat')

        controller.toggleDocked()
        expect(popup.classList.contains('docked-collapsed')).toBe(true)
        expect(controller.closeIconTarget.style.display).toBe('none')
        expect(controller.expandDockedIconTarget.style.display).toBe('')
        expect(controller.expandDockedIconTarget.getAttribute('aria-hidden')).toBe('true')
        expect(controller.expandDockedIconTarget.querySelector('[data-icon="expand"]')).not.toBeNull()
        expect(controller.closeButtonTarget.getAttribute('aria-label')).toBe('Expand chat')

        controller.toggleDocked()
        expect(popup.classList.contains('docked-collapsed')).toBe(false)
        expect(controller.closeIconTarget.style.display).toBe('')
        expect(controller.expandDockedIconTarget.style.display).toBe('none')
        expect(controller.closeButtonTarget.getAttribute('aria-label')).toBe('Collapse chat')
    })

    test('leaving docked mode while collapsed restores the close asset', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.closeLabel = 'Close chat'
        popup.dataset.expandDockedLabel = 'Expand chat'

        controller.enterDockedMode()
        controller.toggleDocked()
        expect(controller.expandDockedIconTarget.style.display).toBe('')

        controller.dockedMediaQuery.matches = false
        controller.syncDockedUI()

        expect(controller.closeIconTarget.style.display).toBe('')
        expect(controller.expandDockedIconTarget.style.display).toBe('none')
    })

    test('restores the floating close button label after leaving docked mode', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.closeLabel = 'Close chat'
        controller.enterDockedMode()
        controller.dockedMediaQuery.matches = false

        controller.syncDockedUI()

        expect(controller.closeIconTarget.style.display).toBe('')
        expect(controller.expandDockedIconTarget.style.display).toBe('none')
        expect(controller.closeButtonTarget.getAttribute('aria-label')).toBe('Close chat')
        expect(controller.closeButtonTarget.title).toBe('Close chat')
    })

    test('empty docked workspace does not request a wake lock', () => {
        const popup = document.getElementById('comments-popup')
        const requestWakeLock = jest.spyOn(controller, '_requestWakeLock')
        const releaseWakeLock = jest.spyOn(controller, '_releaseWakeLock')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = ''

        controller.enterDockedMode()

        expect(requestWakeLock).not.toHaveBeenCalled()
        expect(releaseWakeLock).toHaveBeenCalled()
    })

    test('collapsing docked chat releases wake lock and expanding reacquires it', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        controller.enterDockedMode()
        const requestWakeLock = jest.spyOn(controller, '_requestWakeLock')
        const releaseWakeLock = jest.spyOn(controller, '_releaseWakeLock')

        controller.toggleDocked()

        expect(releaseWakeLock).toHaveBeenCalledTimes(1)
        expect(requestWakeLock).not.toHaveBeenCalled()

        controller.toggleDocked()

        expect(requestWakeLock).toHaveBeenCalledTimes(1)
    })

    test('pending wake lock is released if docked chat collapses before acquisition', async () => {
        const popup = document.getElementById('comments-popup')
        const release = jest.fn()
        let finishRequest
        Object.defineProperty(navigator, 'wakeLock', {
            configurable: true,
            value: {
                request: jest.fn(() => new Promise(resolve => { finishRequest = resolve })),
            },
        })
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        controller.enterDockedMode()

        controller.toggleDocked()
        finishRequest({ release, addEventListener: jest.fn() })
        await Promise.resolve()

        expect(release).toHaveBeenCalledTimes(1)
        expect(controller._wakeLock).toBeNull()
        delete navigator.wakeLock
    })

    test('deduplicates concurrent wake lock requests', async () => {
        const popup = document.getElementById('comments-popup')
        const wakeLock = { release: jest.fn(), addEventListener: jest.fn() }
        let finishRequest
        Object.defineProperty(navigator, 'wakeLock', {
            configurable: true,
            value: {
                request: jest.fn(() => new Promise(resolve => { finishRequest = resolve })),
            },
        })
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.style.display = 'flex'

        const firstRequest = controller._requestWakeLock()
        const secondRequest = controller._requestWakeLock()

        expect(navigator.wakeLock.request).toHaveBeenCalledTimes(1)
        finishRequest(wakeLock)
        await Promise.all([firstRequest, secondRequest])
        expect(controller._wakeLock).toBe(wakeLock)
        delete navigator.wakeLock
    })

    test('docked chat forwards a comment deep link without starting a second open', async () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        window.history.replaceState({}, '', '/creatives/123/comments/456')
        const openForCreative = jest.spyOn(controller, 'openForCreative').mockResolvedValue()
        const openFromUrl = jest.spyOn(controller, 'openFromUrl')

        controller.enterDockedMode()
        await new Promise(resolve => requestAnimationFrame(resolve))
        await new Promise(resolve => setTimeout(resolve, 110))

        expect(openForCreative).toHaveBeenCalledWith({ highlightId: '456' })
        expect(openFromUrl).not.toHaveBeenCalled()
    })

    test('same-creative workspace deep links reload only the highlighted comment window', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.style.display = 'flex'
        const open = jest.spyOn(controller, 'open').mockResolvedValue()
        const listController = {
            onPopupOpened: jest.fn(),
            onPopupClosed: jest.fn(),
        }
        Object.defineProperty(controller, 'listController', {
            configurable: true,
            value: listController,
        })
        Object.defineProperty(controller, 'topicsController', {
            configurable: true,
            value: {
                currentTopicId: '7',
                onPopupClosed: jest.fn(),
            },
        })

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: {
                button: triggerBtn,
                creativeId: '123',
                workspaceSync: true,
                highlightId: '456',
            },
        }))

        expect(open).not.toHaveBeenCalled()
        expect(listController.onPopupOpened).toHaveBeenCalledWith({
            creativeId: '123',
            highlightId: '456',
            topicId: '7',
        })
    })

    test('same-creative deep links clear suppression from a canceled pending open', async () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        let finishTopicsLoad
        const listController = {
            creativeId: null,
            suppressTopicChangeLoad: false,
            onPopupOpened: jest.fn(),
            onPopupClosed: jest.fn(),
        }
        const topicsController = {
            clearOverrideTopicId: jest.fn(),
            currentTopicId: '7',
            onPopupOpened: jest.fn(() => new Promise(resolve => { finishTopicsLoad = resolve })),
            onPopupClosed: jest.fn(),
        }
        Object.defineProperty(controller, 'listController', { configurable: true, value: listController })
        Object.defineProperty(controller, 'topicsController', { configurable: true, value: topicsController })

        const pendingOpen = controller.open(triggerBtn)
        await Promise.resolve()
        expect(listController.suppressTopicChangeLoad).toBe(true)

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: {
                button: triggerBtn,
                creativeId: '123',
                workspaceSync: true,
                highlightId: '456',
            },
        }))

        const suppressionAfterReload = listController.suppressTopicChangeLoad
        expect(listController.onPopupOpened).toHaveBeenCalledWith({
            creativeId: '123',
            highlightId: '456',
            topicId: '7',
        })

        finishTopicsLoad()
        await pendingOpen
        expect(suppressionAfterReload).toBe(false)
    })

    test('same-creative workspace deep links highlight an already loaded comment without reloading', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        const listTarget = document.createElement('div')
        const comment = document.createElement('div')
        comment.id = 'comment_456'
        listTarget.appendChild(comment)
        popup.appendChild(listTarget)
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.style.display = 'flex'
        const listController = {
            listTarget,
            highlightComment: jest.fn(),
            onPopupOpened: jest.fn(),
            onPopupClosed: jest.fn(),
        }
        Object.defineProperty(controller, 'listController', {
            configurable: true,
            value: listController,
        })

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: {
                button: triggerBtn,
                creativeId: '123',
                workspaceSync: true,
                highlightId: '456',
            },
        }))

        expect(listController.highlightComment).toHaveBeenCalledWith('456')
        expect(listController.onPopupOpened).not.toHaveBeenCalled()
    })

    test('same-creative workspace sync without a deep link keeps the docked chat', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.style.display = 'flex'
        const open = jest.spyOn(controller, 'open').mockResolvedValue()

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123', workspaceSync: true },
        }))

        expect(open).not.toHaveBeenCalled()
        expect(popup.dataset.creativeId).toBe('123')
    })

    test('chat icon expands a collapsed docked chat showing the same creative', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.dataset.collapseDockedLabel = 'Collapse chat'
        popup.dataset.expandDockedLabel = 'Expand chat'
        controller.enterDockedMode()
        controller.toggleDocked()
        expect(popup.classList.contains('docked-collapsed')).toBe(true)
        const open = jest.spyOn(controller, 'open').mockResolvedValue()

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123' },
        }))

        expect(popup.classList.contains('docked-collapsed')).toBe(false)
        expect(controller.closeButtonTarget.getAttribute('aria-label')).toBe('Collapse chat')
        // The chat is already loaded for this creative — expanding must not
        // reload it, which would drop the draft and subscriptions.
        expect(open).not.toHaveBeenCalled()
    })

    test('chat icon expands a collapsed docked chat when switching creatives', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '999'
        controller.enterDockedMode()
        controller.toggleDocked()
        const open = jest.spyOn(controller, 'open').mockResolvedValue()

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123' },
        }))

        expect(popup.classList.contains('docked-collapsed')).toBe(false)
        expect(open).toHaveBeenCalledWith(triggerBtn, { creativeId: '123' })
    })

    test('workspace navigation keeps a collapsed docked chat collapsed', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '999'
        controller.enterDockedMode()
        controller.toggleDocked()
        const open = jest.spyOn(controller, 'open').mockResolvedValue()

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123', workspaceSync: true },
        }))

        expect(open).toHaveBeenCalledWith(triggerBtn, { creativeId: '123' })
        expect(popup.classList.contains('docked-collapsed')).toBe(true)
    })

    test('workspace deep links pass the highlight when switching creatives', () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '999'
        popup.style.display = 'flex'
        const open = jest.spyOn(controller, 'open').mockResolvedValue()

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: {
                button: triggerBtn,
                creativeId: '123',
                workspaceSync: true,
                highlightId: '456',
            },
        }))

        expect(open).toHaveBeenCalledWith(triggerBtn, {
            creativeId: '123',
            highlightId: '456',
        })
    })

    test('root workspace navigation resets docked chat to its empty state', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.dataset.defaultTitle = 'Comments'
        popup.dataset.dockedEmptyText = 'Select a creative'
        const state = document.createElement('div')
        state.dataset.workspaceNavigationState = 'true'

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: state, creativeId: undefined },
        }))

        expect(popup.dataset.creativeId).toBe('')
        expect(controller.titleTarget.textContent).toBe('Comments')
        expect(controller.listTarget.textContent).toBe('Select a creative')
        expect(controller.listTarget.classList.contains('docked-empty')).toBe(true)
        expect(popup.style.display).toBe('flex')
    })

    test('resetting a fullscreen docked chat exits fullscreen before showing empty state', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.dataset.fullscreen = 'true'
        popup.dataset.dockedEmptyText = 'Select a creative'
        popup.style.display = 'flex'
        popup.style.position = 'fixed'
        popup.style.width = '100%'
        popup.style.height = '100%'
        document.body.classList.add('chat-fullscreen')
        window.history.replaceState({}, '', '/creatives/123/comments/fullscreen')
        controller._previousUrl = '/creatives/123'

        controller.resetDockedToEmpty()

        expect(popup.dataset.fullscreen).toBe('false')
        expect(document.body.classList.contains('chat-fullscreen')).toBe(false)
        expect(popup.dataset.creativeId).toBe('')
        expect(controller.listTarget.textContent).toBe('Select a creative')
        expect(popup.style.display).toBe('flex')
        expect(popup.style.position).toBe('')
        expect(popup.style.width).toBe('')
        expect(popup.style.height).toBe('')
        expect(window.location.pathname).toBe('/creatives/123')
    })

    test('workspace navigation does not auto-open chat outside the docked layout', async () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        const open = jest.spyOn(controller, 'open')
        popup.dataset.docked = 'true'
        controller.dockedMediaQuery.matches = false

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123', workspaceSync: true },
        }))

        expect(open).not.toHaveBeenCalled()
        expect(popup.style.display).not.toBe('flex')

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123' },
        }))
        await Promise.resolve()

        expect(open).toHaveBeenCalledWith(triggerBtn, { creativeId: '123' })
    })

    test('workspace navigation closes an existing floating chat', async () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        controller.dockedMediaQuery.matches = false
        await controller.open(triggerBtn)

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '456', workspaceSync: true },
        }))

        expect(popup.style.display).toBe('none')
        expect(popup.dataset.creativeId).toBe('123')
    })

    test('late workspace sync keeps a manually opened chat for the same creative', async () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        controller.dockedMediaQuery.matches = false
        await controller.open(triggerBtn)

        document.dispatchEvent(new CustomEvent('creative-comments-click', {
            detail: { button: triggerBtn, creativeId: '123', workspaceSync: true },
        }))

        expect(popup.style.display).toBe('flex')
        expect(popup.dataset.creativeId).toBe('123')
    })

    test('destroying the active creative resets docked chat instead of collapsing it', () => {
        const popup = document.getElementById('comments-popup')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.dataset.defaultTitle = 'Comments'
        popup.dataset.dockedEmptyText = 'Select a creative'
        controller.enterDockedMode()
        const closeChildControllers = jest.spyOn(controller, 'closeChildControllers')

        document.dispatchEvent(new CustomEvent('creative-destroyed', {
            detail: { creativeIds: ['123'] },
        }))

        expect(popup.dataset.creativeId).toBe('')
        expect(controller.listTarget.textContent).toBe('Select a creative')
        expect(popup.classList.contains('docked-collapsed')).toBe(false)
        expect(popup.style.display).toBe('flex')
        expect(closeChildControllers).toHaveBeenCalled()
    })

    test('destroying the active creative closes a floating chat', async () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        await controller.open(triggerBtn)

        document.dispatchEvent(new CustomEvent('creative-destroyed', {
            detail: { creativeIds: ['123'] },
        }))

        expect(popup.style.display).toBe('none')
    })

    test('destroying a creative invalidates its pending docked chat open', async () => {
        const popup = document.getElementById('comments-popup')
        const triggerBtn = document.getElementById('trigger-btn')
        popup.dataset.docked = 'true'
        popup.dataset.creativeId = '123'
        popup.dataset.defaultTitle = 'Comments'
        popup.dataset.dockedEmptyText = 'Select a creative'
        controller.enterDockedMode()

        let finishTopicsLoad
        Object.defineProperty(controller, 'topicsController', {
            configurable: true,
            value: {
                clearOverrideTopicId: jest.fn(),
                onPopupOpened: jest.fn(() => new Promise(resolve => { finishTopicsLoad = resolve })),
                onPopupClosed: jest.fn(),
            },
        })
        const dispatchEvent = jest.spyOn(popup, 'dispatchEvent')
        const pendingOpen = controller.open(triggerBtn)
        await Promise.resolve()

        document.dispatchEvent(new CustomEvent('creative-destroyed', {
            detail: { creativeIds: ['123'] },
        }))
        finishTopicsLoad()
        await pendingOpen

        expect(popup.dataset.creativeId).toBe('')
        expect(dispatchEvent).not.toHaveBeenCalledWith(expect.objectContaining({ type: 'comments-popup:opened' }))
    })

    test('an obsolete open does not clear the current topic suppression guard', async () => {
        const listController = {
            creativeId: null,
            suppressTopicChangeLoad: false,
            onPopupOpened: jest.fn(),
        }
        const pendingTopics = new Map()
        const topicsController = {
            clearOverrideTopicId: jest.fn(),
            currentTopicId: '7',
            onPopupOpened: jest.fn(({ creativeId }) => new Promise(resolve => {
                pendingTopics.set(creativeId, resolve)
            })),
        }
        Object.defineProperty(controller, 'listController', { configurable: true, value: listController })
        Object.defineProperty(controller, 'topicsController', { configurable: true, value: topicsController })

        controller.openGeneration = 1
        const firstOpen = controller.notifyChildControllers({
            creativeId: '123', canComment: true, openGeneration: 1,
        })
        await Promise.resolve()

        controller.openGeneration = 2
        const secondOpen = controller.notifyChildControllers({
            creativeId: '456', canComment: true, openGeneration: 2,
        })
        await Promise.resolve()

        pendingTopics.get('123')()
        expect(await firstOpen).toBe(false)
        expect(listController.suppressTopicChangeLoad).toBe(true)

        pendingTopics.get('456')()
        expect(await secondOpen).toBe(true)
        expect(listController.suppressTopicChangeLoad).toBe(false)
        expect(listController.onPopupOpened).toHaveBeenCalledWith({
            creativeId: '456', highlightId: undefined, topicId: '7',
        })
    })

    test('notifies the form of a chat switch before awaiting topics', async () => {
        let finishTopicsLoad
        const formController = {
            currentTopicId: 'old-topic',
            _mainTopicId: 'old-main',
            onChatWillOpen: jest.fn(),
            onPopupOpened: jest.fn(),
        }
        const topicsController = {
            clearOverrideTopicId: jest.fn(),
            currentTopicId: 'new-topic',
            onPopupOpened: jest.fn(() => new Promise(resolve => { finishTopicsLoad = resolve })),
        }
        Object.defineProperty(controller, 'formController', { configurable: true, value: formController })
        Object.defineProperty(controller, 'topicsController', { configurable: true, value: topicsController })

        controller.openGeneration = 1
        const pendingOpen = controller.notifyChildControllers({
            creativeId: '456', canComment: true, openGeneration: 1,
        })
        await Promise.resolve()

        expect(formController.onChatWillOpen).toHaveBeenCalledWith({ creativeId: '456' })
        expect(formController.onPopupOpened).not.toHaveBeenCalled()

        finishTopicsLoad()
        await pendingOpen
        expect(formController.onPopupOpened).toHaveBeenCalledWith({
            creativeId: '456', canComment: true,
        })
    })

    test('clears stale contexts before awaiting topics and loads them after topics resolve', async () => {
	let finishTopicsLoad
	const topicsController = {
	    clearOverrideTopicId: jest.fn(),
	    currentTopicId: 'new-topic',
	    onPopupOpened: jest.fn(() => new Promise(resolve => { finishTopicsLoad = resolve })),
	}
	const contextsController = {
	    onChatWillOpen: jest.fn(),
	    onPopupOpened: jest.fn(),
	}
	Object.defineProperty(controller, 'topicsController', { configurable: true, value: topicsController })
	Object.defineProperty(controller, 'contextsController', { configurable: true, value: contextsController })

	controller.openGeneration = 1
	const pendingOpen = controller.notifyChildControllers({
	    creativeId: '456', canComment: true, openGeneration: 1,
	})
	await Promise.resolve()

	expect(contextsController.onChatWillOpen).toHaveBeenCalledWith({ creativeId: '456' })
	expect(contextsController.onPopupOpened).not.toHaveBeenCalled()

	finishTopicsLoad()
	await pendingOpen

	expect(contextsController.onPopupOpened).toHaveBeenCalledWith({ creativeId: '456' })
    })

    test('logout submit clears popup size and chat drafts from localStorage', () => {
        window.localStorage.setItem('commentsPopupSize', '{"w":300}')
        window.localStorage.setItem('collavre_chat_drafts_9', '{"77":{"text":"x","updatedAt":1}}')

        const formController = { discardDraft: jest.fn() }
        Object.defineProperty(controller, 'formController', {
            configurable: true,
            value: formController,
        })

        document.getElementById('logout-form').dispatchEvent(
            new Event('submit', { bubbles: true, cancelable: true }),
        )

        expect(formController.discardDraft).toHaveBeenCalledTimes(1)
        expect(window.localStorage.getItem('commentsPopupSize')).toBeNull()
        expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
    })

    test('mounted logout submit clears chat drafts', () => {
	chatDrafts.set('77', 'private draft')

	const formController = { discardDraft: jest.fn() }
	Object.defineProperty(controller, 'formController', {
	    configurable: true,
	    value: formController,
	})

	document.getElementById('mounted-logout-form').dispatchEvent(
	    new Event('submit', { bubbles: true, cancelable: true }),
	)

	expect(formController.discardDraft).toHaveBeenCalledTimes(1)
	expect(chatDrafts.get('77')).toBeNull()
    })

    test('logout submit discards drafts when the localStorage getter is denied', () => {
        const formController = { discardDraft: jest.fn() }
        Object.defineProperty(controller, 'formController', {
            configurable: true,
            value: formController,
        })
        const storageGetter = jest.spyOn(window, 'localStorage', 'get').mockImplementation(() => {
            throw new DOMException('Storage access denied', 'SecurityError')
        })

        try {
            chatDrafts.set('77', 'private draft')

            expect(() => document.getElementById('logout-form').dispatchEvent(
                new Event('submit', { bubbles: true, cancelable: true }),
            )).not.toThrow()

            expect(formController.discardDraft).toHaveBeenCalledTimes(1)
            expect(chatDrafts.get('77')).toBeNull()
        } finally {
            storageGetter.mockRestore()
        }
    })

})
