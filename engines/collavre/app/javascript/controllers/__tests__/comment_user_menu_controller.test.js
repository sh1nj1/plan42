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

  test('inserts a mention and focuses the composer', () => {
    const textareaTarget = { focus: jest.fn() }
    const mentionMenu = { insertMention: jest.fn(), textareaTarget }
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockImplementation((_element, identifier) => (
      identifier === 'comments--mention-menu' ? mentionMenu : null
    ))

    controller.mention()

    expect(mentionMenu.insertMention).toHaveBeenCalledWith({ id: 9, name: 'Agent One' })
    expect(textareaTarget.focus).toHaveBeenCalled()
  })

  test('does nothing when the mention controller is unavailable', () => {
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockReturnValue(null)

    expect(() => controller.mention()).not.toThrow()
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
