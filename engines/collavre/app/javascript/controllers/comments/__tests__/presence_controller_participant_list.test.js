/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import PresenceController from '../presence_controller'

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
            { id: 1, label: 'Ada', avatarUrl: '/avatars/1.png', iconKey: null, muted: false },
            { id: 2, label: 'Grace', avatarUrl: '/avatars/2.png', iconKey: null, muted: true }
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
            expect.any(Array), expect.any(Object), expect.any(Function), controller.element
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
})
