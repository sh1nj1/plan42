/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import CommentUserMenuController from '../comment_user_menu_controller'

describe('CommentUserMenuController', () => {
  let application
  let popup
  let controller

  beforeEach(async () => {
    popup = document.createElement('div')
    popup.dataset.controller = 'comments--presence comments--mention-menu comments--topics'
    popup.innerHTML = `
      <div data-controller="comment-user-menu"
           data-comment-user-menu-user-id-value="9"
           data-comment-user-menu-user-name-value="Agent One">
        <span data-comment-user-menu-target="status"
              data-online-text="Online"
              data-offline-text="Offline">
          <span data-comment-user-menu-target="statusLabel">Offline</span>
        </span>
      </div>
    `
    document.body.appendChild(popup)

    application = Application.start()
    application.register('comment-user-menu', CommentUserMenuController)
    await new Promise((resolve) => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(
      popup.querySelector('[data-controller="comment-user-menu"]'),
      'comment-user-menu'
    )
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('updates the localized status when presence changes', () => {
    popup.dispatchEvent(new CustomEvent('comments--presence:changed', {
      detail: { presentIds: [9] },
    }))

    expect(controller.statusTarget.classList.contains('is-online')).toBe(true)
    expect(controller.statusLabelTarget.textContent).toBe('Online')

    popup.dispatchEvent(new CustomEvent('comments--presence:changed', {
      detail: { presentIds: [] },
    }))

    expect(controller.statusTarget.classList.contains('is-online')).toBe(false)
    expect(controller.statusLabelTarget.textContent).toBe('Offline')
  })

  // A gateway-backed agent is online without being present in the chat, and the
  // avatar on its message must not contradict the one in the participant strip.
  test('defers to the presence controller so agent liveness reads the same everywhere', () => {
    const presence = {
      userHealthState: jest.fn(() => ({ online: true, kind: 'online', label: 'Online' }))
    }
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockImplementation((_element, identifier) => (
      identifier === 'comments--presence' ? presence : null
    ))

    popup.dispatchEvent(new CustomEvent('comments--presence:changed', { detail: { presentIds: [] } }))

    expect(presence.userHealthState).toHaveBeenCalledWith(9, [])
    expect(controller.statusTarget.classList.contains('is-online')).toBe(true)
    expect(controller.statusLabelTarget.textContent).toBe('Online')
  })

  test('shows a checker error returned by the presence controller', () => {
    const presence = {
      userHealthState: jest.fn(() => ({ online: false, kind: 'check_error', label: 'Health check error' }))
    }
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockImplementation((_element, identifier) => (
      identifier === 'comments--presence' ? presence : null
    ))

    controller.updatePresence([])

    expect(controller.statusTarget.classList.contains('is-check_error')).toBe(true)
    expect(controller.statusLabelTarget.textContent).toBe('Health check error')
  })

  test('inserts a mention and focuses the composer', () => {
    const textareaTarget = { focus: jest.fn() }
    const mentionMenu = { insertMention: jest.fn(), textareaTarget }
    const popupMenu = { hide: jest.fn() }
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockImplementation((_element, identifier) => {
      if (identifier === 'comments--mention-menu') return mentionMenu
      if (identifier === 'popup-menu') return popupMenu
      return null
    })
    const event = { stopPropagation: jest.fn() }

    controller.mention(event)

    expect(event.stopPropagation).toHaveBeenCalled()
    expect(mentionMenu.insertMention).toHaveBeenCalledWith({ id: 9, name: 'Agent One' })
    expect(textareaTarget.focus).toHaveBeenCalled()
    expect(popupMenu.hide).toHaveBeenCalled()
  })

  test('keeps the menu open when the mention controller is unavailable', () => {
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockReturnValue(null)
    const event = { stopPropagation: jest.fn() }

    expect(() => controller.mention(event)).not.toThrow()
    expect(event.stopPropagation).toHaveBeenCalled()
  })

  test('keeps profile navigation from being interrupted by the popup close handler', () => {
    const event = { stopPropagation: jest.fn() }

    controller.visitProfile(event)

    expect(event.stopPropagation).toHaveBeenCalled()
  })

  test('removes the presence listener when disconnected', () => {
    const removeEventListener = jest.spyOn(popup, 'removeEventListener')

    controller.disconnect()

    expect(removeEventListener).toHaveBeenCalledWith(
      'comments--presence:changed',
      controller.handlePresenceChanged
    )
  })

  test('ignores presence updates when status targets are absent', async () => {
    controller.element.querySelector('[data-comment-user-menu-target="status"]').remove()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(() => controller.updatePresence([9])).not.toThrow()
  })
})
