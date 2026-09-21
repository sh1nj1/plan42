/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import FormController from '../form_controller'

// Regression harness for: the chat textarea's default-state placeholder was
// always empty (''), wasting a UI slot. It should now show a slash-command
// hint whenever the form is in its normal (non-review, non-quote) state.
describe('FormController - default placeholder hint', () => {
  let application
  let container
  let controller

  const FIXTURE = `
    <div id="comments-popup"
         data-controller="comments--form"
         data-chat-input-hint="Type a message, or use / for commands"
         data-review-feedback-placeholder="Write feedback for this quote..."
         data-review-summary-placeholder="Overall comment (optional)...">
      <form data-comments--form-target="form">
        <input type="hidden" name="comment[quoted_comment_id]" data-comments--form-target="quotedCommentId" value="" />
        <input type="hidden" name="comment[quoted_text]" data-comments--form-target="quotedText" value="" />
        <div data-comments--form-target="quoteIndicator" style="display:none;">
          <span data-comments--form-target="quoteIndicatorText"></span>
        </div>
        <div class="review-quotes-container" data-comments--form-target="reviewQuotesContainer" style="display:none;"></div>
        <textarea data-comments--form-target="textarea" rows="2"></textarea>
        <input type="checkbox" data-comments--form-target="privateCheckbox" />
        <button type="submit" data-comments--form-target="submit">Send</button>
        <button data-comments--form-target="cancel" style="display:none;">Cancel</button>
        <button data-comments--form-target="moveButton" style="display:none;">Move</button>
        <button data-comments--form-target="searchButton" style="display:none;">Search</button>
        <button data-comments--form-target="voiceButton" style="display:none;">Voice</button>
        <input type="file" data-comments--form-target="imageInput" style="display:none;" />
        <button data-comments--form-target="imageButton" style="display:none;">Image</button>
        <div data-comments--form-target="attachmentList"></div>
      </form>
    </div>`

  beforeEach(async () => {
    container = document.createElement('div')
    container.innerHTML = FIXTURE
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--form', FormController)
    await new Promise((r) => setTimeout(r, 50))
    controller = application.getControllerForElementAndIdentifier(
      container.querySelector('#comments-popup'),
      'comments--form',
    )
  })

  afterEach(() => {
    application.stop()
    document.body.removeChild(container)
  })

  test('resetForm() shows the slash-command hint instead of an empty placeholder', () => {
    // jsdom's FileList is not constructible; clearImageAttachments() is
    // unrelated to placeholder behavior, so stub it out (same workaround as
    // form_controller_double_submit.test.js's SCENARIO C).
    jest.spyOn(controller, 'clearImageAttachments').mockImplementation(() => {})
    controller.resetForm()
    expect(controller.textareaTarget.placeholder).toBe('Type a message, or use / for commands')
  })

  test('cancelQuote() restores the slash-command hint', () => {
    controller.textareaTarget.placeholder = 'Write feedback for this quote...'
    controller.cancelQuote()
    expect(controller.textareaTarget.placeholder).toBe('Type a message, or use / for commands')
  })

  test('falls back to the English default when no data-chat-input-hint is present', () => {
    jest.spyOn(controller, 'clearImageAttachments').mockImplementation(() => {})
    container.querySelector('#comments-popup').removeAttribute('data-chat-input-hint')
    controller.resetForm()
    expect(controller.textareaTarget.placeholder).toBe('Type a message, or use / for commands')
  })
})
