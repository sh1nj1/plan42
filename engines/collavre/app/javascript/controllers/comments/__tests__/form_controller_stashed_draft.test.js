/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsFormController from '../form_controller'

// A slash command with an input schema takes over the textarea and submits
// itself (modules/command_menu.js `argsForm.onSubmit`), so a draft the user had
// already typed cannot go out with it. The menu hands the draft over on a
// `comments--form:stash-draft` event and the controller puts it back once the
// send settles.
const buildController = () => {
  document.body.innerHTML = '<div id="comments-popup"><textarea></textarea></div>'
  const textarea = document.querySelector('textarea')

  const controller = Object.create(CommentsFormController.prototype)
  Object.defineProperty(controller, 'textareaTarget', { get: () => textarea })
  controller._autoResize = jest.fn()
  controller._updateSubmitButton = jest.fn()

  return { controller, textarea }
}

describe('CommentsFormController stashed draft', () => {
  test('stashes the draft carried by the event', () => {
    const { controller } = buildController()

    controller.handleStashDraft(
      new CustomEvent('comments--form:stash-draft', { detail: { draft: 'roadmap notes' } }),
    )

    expect(controller._stashedDraft).toBe('roadmap notes')
  })

  test('receives the event dispatched on the textarea, which bubbles to the popup', () => {
    // command_menu.js dispatches on `#new-comment-form textarea`, and the
    // comments--form controller element is `#comments-popup`, which wraps the
    // form (_comments_popup.html.erb). The stash only arrives if it bubbles.
    const { controller, textarea } = buildController()
    const element = document.getElementById('comments-popup')
    element.addEventListener(
      'comments--form:stash-draft',
      controller.handleStashDraft.bind(controller),
    )

    textarea.dispatchEvent(
      new CustomEvent('comments--form:stash-draft', {
        bubbles: true,
        detail: { draft: 'roadmap notes' },
      }),
    )

    expect(controller._stashedDraft).toBe('roadmap notes')
  })

  test('restores the draft into the textarea the send cleared', () => {
    const { controller, textarea } = buildController()
    controller._stashedDraft = 'roadmap notes'

    // The success path runs resetForm() before .finally(), so the box is empty.
    textarea.value = ''
    controller._restoreStashedDraft()

    expect(textarea.value).toBe('roadmap notes')
    expect(controller._autoResize).toHaveBeenCalledTimes(1)
    expect(controller._updateSubmitButton).toHaveBeenCalledTimes(1)
  })

  test('does not clobber text the user typed while the command was in flight', () => {
    const { controller, textarea } = buildController()
    controller._stashedDraft = 'roadmap notes'

    textarea.value = 'something else entirely'
    controller._restoreStashedDraft()

    expect(textarea.value).toBe('something else entirely')
  })

  test('consumes the stash so a later send does not resurrect it', () => {
    const { controller, textarea } = buildController()
    controller._stashedDraft = 'roadmap notes'

    controller._restoreStashedDraft()
    expect(controller._stashedDraft).toBeNull()

    textarea.value = ''
    controller._restoreStashedDraft()
    expect(textarea.value).toBe('')
  })

  test('is a no-op for an ordinary send with nothing stashed', () => {
    const { controller, textarea } = buildController()

    controller._restoreStashedDraft()

    expect(textarea.value).toBe('')
    expect(controller._autoResize).not.toHaveBeenCalled()
  })
})
