/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import MentionMenuController from '../mention_menu_controller'

describe('CommentsMentionMenuController', () => {
  let application
  let controller
  let textarea

  beforeEach(async () => {
    document.body.innerHTML = `
      <div id="comments-popup" data-controller="comments--mention-menu">
        <div data-comments--mention-menu-target="participants">
          <button type="button" class="comment-user-menu-trigger">
            <img class="comment-presence-avatar" data-user-id="9" data-user-name="Agent One">
          </button>
        </div>
        <textarea data-comments--mention-menu-target="textarea">Hello </textarea>
      </div>
    `

    application = Application.start()
    application.register('comments--mention-menu', MentionMenuController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    const element = document.getElementById('comments-popup')
    controller = application.getControllerForElementAndIdentifier(element, 'comments--mention-menu')
    textarea = element.querySelector('textarea')
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('does not insert a mention when a participant avatar opens its profile menu', () => {
    const focus = jest.spyOn(textarea, 'focus')

    document.querySelector('.comment-presence-avatar').click()

    expect(textarea.value).toBe('Hello ')
    expect(focus).not.toHaveBeenCalled()
  })

  test('inserts a mention only when explicitly requested', () => {
    textarea.setSelectionRange(6, 6)

    controller.insertMention({ id: 9, name: 'Agent One' })

    expect(textarea.value).toBe('Hello @Agent One: ')
    expect(textarea.selectionStart).toBe(18)
    expect(textarea.selectionEnd).toBe(18)
  })
})
