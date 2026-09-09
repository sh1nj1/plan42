/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import PresenceController from '../presence_controller'

describe('CommentsPresenceController — gateway-backed agent liveness', () => {
    let application, controller

    const HUMAN = {
        id: 1, name: 'Ada', email: 'ada@example.com', avatar_url: '/avatars/1.png',
        profile_url: '/users/1', ai_user: false, default_avatar: false, initial: 'A', agent_online: false
    }
    const AGENT = {
        id: 2, name: 'Grace', email: 'grace@ai.local', avatar_url: '/avatars/2.png',
        profile_url: '/users/2', ai_user: true, default_avatar: false, initial: 'G', agent_online: true
    }

    const isMenuOnline = (userId) => {
        const menu = controller.participantsTarget
            .querySelector(`[data-comment-user-menu-user-id-value="${userId}"]`)
        return menu.querySelector('.comment-user-popup-status').classList.contains('is-online')
    }

    beforeEach(async () => {
        global.requestAnimationFrame = (fn) => { fn(); return 0 }
        global.fetch = jest.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve({}) }))

        document.body.innerHTML = `
          <div id="comments-popup" data-controller="comments--presence"
               data-close-label="Close"
               data-participant-online-text="Online"
               data-participant-offline-text="Offline"
               data-participant-search-placeholder-text="Search users..."
               data-user-menu-open-text="Open %{name}'s profile menu"
               data-user-menu-view-profile-text="View profile"
               data-user-menu-mention-text="Mention"
               data-user-menu-agent-drag-guide-text="Drag this avatar to a topic.">
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

    test('an agent its gateway can serve is online with nobody in the chat', () => {
        controller.participantsData = [HUMAN, AGENT]
        controller.renderParticipants([])

        expect(isMenuOnline(2)).toBe(true)
        expect(isMenuOnline(1)).toBe(false)
    })

    test('chat presence still drives the humans', () => {
        controller.participantsData = [HUMAN, { ...AGENT, agent_online: false }]
        controller.renderParticipants([1])

        expect(isMenuOnline(1)).toBe(true)
        expect(isMenuOnline(2)).toBe(false)
    })

    // Read receipts answer "who has seen this", which an agent nobody is sitting
    // in front of has not. Gateway liveness must not leak into that answer.
    test('agent liveness is kept out of read receipts and the presence event', () => {
        controller.participantsData = [HUMAN, AGENT]
        const dispatched = []
        controller.element.addEventListener('comments--presence:changed', (event) => dispatched.push(event.detail))

        controller.handlePresenceMessage({ ids: [1] })

        expect(controller.updateReadReceiptPresence).toHaveBeenCalledWith([1])
        expect(controller.currentPresentIds).toEqual([1])
        expect(dispatched).toEqual([{ presentIds: [1] }])
    })

    test('an in-place presence update keeps the agent online', () => {
        controller.participantsData = [HUMAN, AGENT]
        controller.renderParticipants([1])

        expect(controller.updateRenderedParticipantPresence([])).toBe(true)
        expect(isMenuOnline(2)).toBe(true)
        expect(isMenuOnline(1)).toBe(false)
    })

    test('the periodic refresh preserves the rendered menus', async () => {
        controller.participantsData = [HUMAN, AGENT]
        controller.renderParticipants([])
        const menuBefore = controller.participantsTarget.querySelector('[data-comment-user-menu-user-id-value="2"]')

        global.fetch = jest.fn(() => Promise.resolve({
            ok: true,
            json: () => Promise.resolve({
                users: [HUMAN, { ...AGENT, agent_online: false }], can_share: false, can_comment: true
            })
        }))
        await controller.loadParticipants('42', { preserveMenus: true })

        expect(controller.participantsTarget.querySelector('[data-comment-user-menu-user-id-value="2"]'))
            .toBe(menuBefore)
        expect(isMenuOnline(2)).toBe(false)
    })
})
