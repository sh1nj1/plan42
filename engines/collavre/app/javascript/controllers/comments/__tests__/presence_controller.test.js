/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import PresenceController from '../presence_controller'

describe('CommentsPresenceController', () => {
  let application
  let container
  let controller

  beforeEach(async () => {
    document.body.dataset.currentUserId = '7'
    global.fetch = jest.fn()
    global.alert = jest.fn()

    container = document.createElement('div')
    container.innerHTML = `
      <div id="comments-popup"
           data-controller="comments--presence"
           data-no-permission-text="No permission">
        <div data-comments--presence-target="participants"></div>
        <div data-comments--presence-target="typingIndicator"></div>
        <textarea data-comments--presence-target="textarea"></textarea>
        <input type="checkbox" data-comments--presence-target="privateCheckbox" />
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--presence', PresenceController)

    await new Promise((resolve) => setTimeout(resolve, 0))
    const el = document.getElementById('comments-popup')
    controller = application.getControllerForElementAndIdentifier(el, 'comments--presence')
    controller.creativeId = '123'
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    delete document.body.dataset.currentUserId
    jest.restoreAllMocks()
  })

  test('hides comment input immediately when affected user loses comment permission', () => {
    const loadParticipantsSpy = jest.spyOn(controller, 'loadParticipants').mockImplementation(() => {})
    const setCommentPermission = jest.fn()
    const close = jest.fn()

    jest.spyOn(controller, 'formController', 'get').mockReturnValue({ setCommentPermission })
    jest.spyOn(controller, 'popupController', 'get').mockReturnValue({ close })
    jest.spyOn(controller, 'listController', 'get').mockReturnValue({ loadInitialComments: jest.fn() })

    controller.handlePresenceMessage({
      shares_changed: {
        user_id: 7,
        has_access: true,
        can_comment: false,
        has_access_changed: false,
        can_comment_changed: true,
      },
    })

    expect(setCommentPermission).toHaveBeenCalledWith(false)
    expect(loadParticipantsSpy).toHaveBeenCalledWith({ closeOnForbidden: false })
    expect(close).not.toHaveBeenCalled()
  })

  test('closes popup when affected user loses access', async () => {
    const close = jest.fn()
    jest.spyOn(controller, 'popupController', 'get').mockReturnValue({ close })
    jest.spyOn(controller, 'formController', 'get').mockReturnValue({ setCommentPermission: jest.fn() })

    global.fetch.mockResolvedValue({
      ok: false,
      json: async () => ({ error: 'No permission' }),
    })

    controller.handlePresenceMessage({
      shares_changed: {
        user_id: 7,
        has_access: false,
        can_comment: false,
        has_access_changed: true,
        can_comment_changed: true,
      },
    })

    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(global.alert).toHaveBeenCalledWith('No permission')
    expect(close).toHaveBeenCalled()
  })

  test('keeps popup open for unaffected users and only refreshes participants', () => {
    const loadParticipantsSpy = jest.spyOn(controller, 'loadParticipants').mockImplementation(() => {})
    const close = jest.fn()
    const setCommentPermission = jest.fn()
    const loadInitialComments = jest.fn()

    jest.spyOn(controller, 'popupController', 'get').mockReturnValue({ close })
    jest.spyOn(controller, 'formController', 'get').mockReturnValue({ setCommentPermission })
    jest.spyOn(controller, 'listController', 'get').mockReturnValue({ loadInitialComments })

    controller.handlePresenceMessage({
      shares_changed: {
        user_id: 99,
        has_access: true,
        can_comment: true,
        has_access_changed: false,
        can_comment_changed: false,
      },
    })

    expect(loadParticipantsSpy).toHaveBeenCalledWith()
    expect(setCommentPermission).not.toHaveBeenCalled()
    expect(loadInitialComments).not.toHaveBeenCalled()
    expect(close).not.toHaveBeenCalled()
  })
})
