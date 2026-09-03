/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import PresenceController from '../presence_controller'
import EntityListController from '../../entity_list_controller'

describe('CommentsPresenceController — pinned add/list buttons', () => {
    let application, controller

    const USERS = [
        { id: 1, name: 'Ada', avatar_url: '/avatars/1.png' },
        { id: 2, name: 'Grace', avatar_url: '/avatars/2.png' }
    ]

    beforeEach(async () => {
        global.requestAnimationFrame = (fn) => { fn(); return 0 }
        global.fetch = jest.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve({}) }))

        document.body.innerHTML = `
          <div id="comments-popup" data-controller="comments--presence"
               data-close-label="Close"
               data-participant-online-text="Online"
               data-participant-offline-text="Offline"
               data-participant-search-placeholder-text="Search users...">
            <div data-comments--presence-target="participants"></div>
            <button class="add-participant-btn" data-comments--presence-target="addParticipantButton" style="display:none;">+</button>
            <button class="bar-list-btn" data-comments--presence-target="participantListButton"
                    aria-expanded="false" style="display:none;"></button>
            <div data-comments--presence-target="typingIndicator"></div>
            <textarea data-comments--presence-target="textarea"></textarea>
            <input type="checkbox" data-comments--presence-target="privateCheckbox" />
          </div>
        `
        application = Application.start()
        application.register('comments--presence', PresenceController)
        application.register('entity-list', EntityListController)
        await new Promise((resolve) => setTimeout(resolve, 0))
        controller = application.getControllerForElementAndIdentifier(
            document.getElementById('comments-popup'), 'comments--presence'
        )
        controller.creativeId = '42'
        jest.spyOn(controller, 'updateReadReceiptPresence').mockImplementation(() => {})
    })

    afterEach(() => {
        document.body.innerHTML = ''
        application.stop()
        jest.restoreAllMocks()
    })

    const anchorEvent = () => ({ currentTarget: controller.participantListButtonTarget })

    test('renders no add button inside the scrolling avatar strip', () => {
        controller.participantsData = USERS
        controller.canShare = true
        controller.renderParticipants([1])

        expect(controller.participantsTarget.querySelector('.add-participant-btn')).toBeNull()
    })

    test('shows the pinned add button only when the user can share', () => {
        controller.participantsData = USERS
        controller.canShare = true
        controller.renderParticipants([])
        expect(controller.addParticipantButtonTarget.style.display).toBe('')
        expect(controller.addParticipantButtonTarget.dataset.shareModalUrlParam).toBe('/creatives/42/creative_shares')

        controller.canShare = false
        controller.renderParticipants([])
        expect(controller.addParticipantButtonTarget.style.display).toBe('none')
    })

    test('hides the list button until there are participants', () => {
        controller.participantsData = null
        controller.renderParticipants([])
        expect(controller.participantListButtonTarget.style.display).toBe('none')

        controller.participantsData = USERS
        controller.renderParticipants([])
        expect(controller.participantListButtonTarget.style.display).toBe('')
    })

    test('builds list items with avatars, marking absent users as muted', () => {
        controller.participantsData = USERS
        controller.currentPresentIds = [1]

        expect(controller.participantListItems()).toEqual([
            {
                id: 1, label: 'Ada', avatarUrl: '/avatars/1.png', iconKey: null,
                muted: false, statusLabel: 'Online'
            },
            {
                id: 2, label: 'Grace', avatarUrl: '/avatars/2.png', iconKey: null,
                muted: true, statusLabel: 'Offline'
            }
        ])
    })

    test('creates the entity-list modal caged inside the chat box', () => {
        controller.participantsData = USERS
        controller.openParticipantListPopup(anchorEvent())

        const modal = document.getElementById('participant-list-modal')
        expect(modal).not.toBeNull()
        expect(modal.dataset.controller).toBe('entity-list')
        expect(modal.parentElement).toBe(controller.element)
        expect(modal.querySelector('[data-entity-list-target="input"]').placeholder).toBe('Search users...')
        expect(modal.querySelector('[data-entity-list-target="list"]')).not.toBeNull()
        expect(modal.querySelector('[data-entity-list-target="close"]')).not.toBeNull()
    })

    test('gives the popup close button the localized accessible label', async () => {
        controller.participantsData = USERS
        controller.openParticipantListPopup(anchorEvent())
        await new Promise((resolve) => setTimeout(resolve, 0))

        expect(document.querySelector('#participant-list-modal .popup-close-btn').getAttribute('aria-label')).toBe('Close')
    })

    test('toggles an open popup closed and clears the button state', () => {
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.openParticipantListPopup(anchorEvent())

        expect(popup.close).toHaveBeenCalled()
        expect(controller.participantListButtonTarget.getAttribute('aria-expanded')).toBe('false')
    })

    test('marks the button expanded while open and clears it on close', () => {
        controller.participantsData = USERS
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => false }, openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.openParticipantListPopup(anchorEvent())
        expect(popup.openForItems).toHaveBeenCalledWith(
            expect.any(Array), expect.any(Function), expect.any(Function), controller.element
        )
        expect(controller.participantListButtonTarget.getAttribute('aria-expanded')).toBe('true')

        modal.dispatchEvent(new CustomEvent('entity-list:close', { bubbles: true }))
        expect(controller.participantListButtonTarget.getAttribute('aria-expanded')).toBe('false')
    })

    test('ignores close events from another popup sharing the entity-list controller', () => {
        controller.setParticipantListButtonExpanded(true)
        const other = document.createElement('div')
        other.id = 'context-list-modal'
        controller.element.appendChild(other)

        other.dispatchEvent(new CustomEvent('entity-list:close', { bubbles: true }))

        expect(controller.participantListButtonTarget.getAttribute('aria-expanded')).toBe('true')
    })

    test('a pointerdown that closed the popup swallows the following click', () => {
        controller.participantsData = USERS
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn(), openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.prepareParticipantListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.participantListButtonTarget
        })
        controller.openParticipantListPopup(anchorEvent())

        expect(popup.openForItems).not.toHaveBeenCalled()
    })

    test('a pointerdown with no popup open lets the click through', () => {
        controller.participantsData = USERS
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => false }, openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.prepareParticipantListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.participantListButtonTarget
        })
        controller.openParticipantListPopup(anchorEvent())

        expect(popup.openForItems).toHaveBeenCalled()
    })

    test('releasing the pointer outside the button re-arms the click', () => {
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)
        jest.spyOn(controller.participantListButtonTarget, 'getBoundingClientRect')
            .mockReturnValue({ left: 10, right: 20, top: 10, bottom: 20 })

        controller.prepareParticipantListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.participantListButtonTarget
        })
        controller.finishParticipantListToggle({
            currentTarget: controller.participantListButtonTarget, clientX: 99, clientY: 99, pointerId: 1
        })
        controller.openParticipantListPopup(anchorEvent())

        expect(popup.close).toHaveBeenCalled()
    })

    test('cancelling the gesture lets the next click through', () => {
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, close: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.prepareParticipantListToggle({
            isPrimary: true, button: 0, pointerId: 1, currentTarget: controller.participantListButtonTarget
        })
        controller.cancelParticipantListToggle({ pointerId: 1 })
        controller.openParticipantListPopup(anchorEvent())

        expect(popup.close).toHaveBeenCalled()
    })

    test('selecting a user mentions them in the composer, like clicking the avatar', () => {
        controller.participantsData = USERS
        const insertMention = jest.fn()
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue({ insertMention })

        controller.selectParticipantListItem({ id: 2 })

        expect(insertMention).toHaveBeenCalledWith({ id: 2, name: 'Grace' })
        expect(document.activeElement).toBe(controller.textareaTarget)
    })

    test('selecting a user who is no longer listed is a no-op', () => {
        controller.participantsData = USERS
        const insertMention = jest.fn()
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue({ insertMention })

        controller.selectParticipantListItem({ id: 99 })

        expect(insertMention).not.toHaveBeenCalled()
    })

    test('passes a live list-button anchor to the popup', () => {
        const firstRect = { top: 10, left: 20, bottom: 30, right: 40 }
        const secondRect = { top: 110, left: 120, bottom: 130, right: 140 }
        const getRect = jest.spyOn(controller.participantListButtonTarget, 'getBoundingClientRect')
            .mockReturnValueOnce(firstRect)
            .mockReturnValue(secondRect)
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => false }, openForItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.openParticipantListPopup(anchorEvent())
        const anchor = popup.openForItems.mock.calls[0][1]

        expect(anchor()).toBe(firstRect)
        expect(anchor()).toBe(secondRect)
        expect(getRect).toHaveBeenCalledTimes(2)
    })

    test('re-rendering refreshes an open popup so presence changes are reflected', () => {
        const modal = document.createElement('div')
        modal.id = 'participant-list-modal'
        controller.element.appendChild(modal)
        const popup = { popup: { isOpen: () => true }, updateItems: jest.fn() }
        jest.spyOn(controller.application, 'getControllerForElementAndIdentifier').mockReturnValue(popup)

        controller.participantsData = USERS
        controller.renderParticipants([1, 2])

        expect(popup.updateItems).toHaveBeenCalledWith([
            expect.objectContaining({ id: 1, muted: false }),
            expect.objectContaining({ id: 2, muted: false })
        ])
    })

    test('switching creatives clears the old popup, participants, and share URL', async () => {
        controller.participantsData = USERS
        controller.canShare = true
        controller.renderParticipants([])
        controller.openParticipantListPopup(anchorEvent())
        await new Promise((resolve) => setTimeout(resolve, 0))
        jest.spyOn(controller, 'loadParticipants').mockImplementation(() => {})
        jest.spyOn(controller, 'subscribe').mockImplementation(() => {})
        jest.spyOn(controller, 'bootstrapChannelChips').mockImplementation(() => {})

        controller.onPopupOpened({ creativeId: '77' })

        expect(document.getElementById('participant-list-modal')).toBeNull()
        expect(controller.participantsData).toBeNull()
        expect(controller.canShare).toBe(false)
        expect(controller.addParticipantButtonTarget.style.display).toBe('none')
        expect(controller.addParticipantButtonTarget.dataset.shareModalUrlParam).toBeUndefined()
        expect(controller.participantListButtonTarget.getAttribute('aria-expanded')).toBe('false')
    })

    test('preparing a creative switch clears stale participants before starting the next load', async () => {
        controller.participantsData = USERS
        controller.canShare = true
        controller.renderParticipants([])
        controller.openParticipantListPopup(anchorEvent())
        await new Promise((resolve) => setTimeout(resolve, 0))
        const loadParticipants = jest.spyOn(controller, 'loadParticipants')

        controller.onChatWillOpen({ creativeId: '77' })

        expect(controller.creativeId).toBe('77')
        expect(document.getElementById('participant-list-modal')).toBeNull()
        expect(controller.participantsData).toBeNull()
        expect(controller.canShare).toBe(false)
        expect(loadParticipants).not.toHaveBeenCalled()
    })

    test('unsubscribes from the previous creative before assigning the next creative id', () => {
        controller.creativeId = '42'
        const creativeIdsAtUnsubscribe = []
        jest.spyOn(controller, 'unsubscribe').mockImplementation(() => {
            creativeIdsAtUnsubscribe.push(controller.creativeId)
        })

        controller.onChatWillOpen({ creativeId: '77' })

        expect(creativeIdsAtUnsubscribe).toEqual(['42'])
        expect(controller.creativeId).toBe('77')
    })

    test('closing an empty dock clears the previous creative share state', () => {
        controller.participantsData = USERS
        controller.canShare = true
        controller.renderParticipants([])

        controller.onPopupClosed()

        expect(controller.creativeId).toBeNull()
        expect(controller.canShare).toBe(false)
        expect(controller.addParticipantButtonTarget.style.display).toBe('none')
        expect(controller.addParticipantButtonTarget.dataset.shareModalUrlParam).toBeUndefined()
    })

    test('ignores a participants response from the creative that was left', async () => {
        let resolveOld
        let resolveCurrent
        global.fetch
            .mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve }))
            .mockImplementationOnce(() => new Promise((resolve) => { resolveCurrent = resolve }))

        const oldLoad = controller.loadParticipants('42')
        controller.creativeId = '77'
        const currentLoad = controller.loadParticipants('77')
        resolveCurrent({
            ok: true,
            json: async () => ({ users: [USERS[1]], can_share: true, can_comment: true })
        })
        await currentLoad
        resolveOld({
            ok: true,
            json: async () => ({ users: [USERS[0]], can_share: false, can_comment: false })
        })
        await oldLoad

        expect(controller.participantsData).toEqual([USERS[1]])
        expect(controller.canShare).toBe(true)
    })

    test('clears participant controls when the current load fails', async () => {
        controller.participantsData = USERS
        controller.canShare = true
        controller.renderParticipants([])
        global.fetch.mockRejectedValueOnce(new Error('network failed'))

        await controller.loadParticipants('42')

        expect(controller.participantsData).toEqual([])
        expect(controller.canShare).toBe(false)
        expect(controller.addParticipantButtonTarget.style.display).toBe('none')
        expect(controller.participantListButtonTarget.style.display).toBe('none')
    })
})
