/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import FormController from '../form_controller'

// Regression harness for: "slow send API + double Enter => message sent twice".
//
// Scenario A proves the in-flight guard blocks a second Enter on the same
// controller instance. Scenario B reproduces the real-world bug: a Turbo/
// websocket morph reconnects the Stimulus controller mid-send, and (before the
// fix) connect() reset this.sending, blowing away the guard so an impatient
// second Enter re-sent the same message.
describe('FormController - double submit on slow API', () => {
  let application
  let container
  let controller

  const FIXTURE = `
    <div id="comments-popup"
         data-controller="comments--form"
         data-review-feedback-placeholder="Write feedback for this quote..."
         data-review-summary-placeholder="Overall comment (optional)..."
         data-review-add-quote="+ Add"
         data-review-send="Send review"
         data-review-send-question="Send question"
         data-review-type-review="💬"
         data-review-type-question="❓"
         data-review-type-review-label="Review"
         data-review-type-question-label="Question">
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
    const meta = document.createElement('meta')
    meta.name = 'csrf-token'
    meta.content = 'test-token'
    document.head.appendChild(meta)

    if (!global.DataTransfer) {
      global.DataTransfer = class {
        constructor() {
          this.files = []
          this.items = { add: (file) => this.files.push(file) }
        }
      }
    }

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
    controller.creativeId = '123'
    controller.currentTopicId = '10073'
  })

  afterEach(() => {
    application.stop()
    document.body.removeChild(container)
  })

  const pressEnter = (textarea) => {
    textarea.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }),
    )
  }

  test('SCENARIO A: two Enter presses while a fetch is in-flight => fetch fires only once', () => {
    const fetchSpy = jest.fn(() => new Promise(() => {})) // never resolves: slow API
    global.fetch = fetchSpy
    controller.creativeId = '111'

    const textarea = controller.textareaTarget
    textarea.value = 'hello world'

    pressEnter(textarea)
    pressEnter(textarea) // impatient second Enter

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  test('SCENARIO B: a controller reconnect (morph) mid-send must NOT re-enable sending', () => {
    const fetchSpy = jest.fn(() => new Promise(() => {})) // never resolves: slow API
    global.fetch = fetchSpy
    controller.creativeId = '222'

    const textarea = controller.textareaTarget
    textarea.value = 'hello world'

    pressEnter(textarea)
    expect(fetchSpy).toHaveBeenCalledTimes(1)

    // A Turbo Stream / websocket broadcast morphs the comments area while the
    // request is still in flight. Stimulus reconnects the controller, which
    // resets the instance-only `this.sending` flag back to false.
    controller.disconnect()
    controller.connect()
    controller.creativeId = '222'
    controller.currentTopicId = '10073'

    // The morph preserves the user's typed text; the impatient user hits Enter
    // again because the slow API still has not responded.
    controller.textareaTarget.value = 'hello world'
    pressEnter(controller.textareaTarget)

    // Durable (module-scope) guard must still block the duplicate.
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  test('SCENARIO C: after the request completes, the next message sends normally', async () => {
    let resolveFetch
    const fetchSpy = jest.fn(
      () => new Promise((resolve) => { resolveFetch = resolve }),
    )
    global.fetch = fetchSpy
    controller.creativeId = '333'
    // Avoid touching the comment list / DOM rendering on success.
    jest.spyOn(controller, 'resetForm').mockImplementation(() => {})

    const textarea = controller.textareaTarget
    textarea.value = 'first'
    pressEnter(textarea)
    expect(fetchSpy).toHaveBeenCalledTimes(1)

    // Resolve the first request, then let the promise microtasks (then/finally) run.
    resolveFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((r) => setTimeout(r, 0))

    controller.textareaTarget.value = 'second'
    pressEnter(controller.textareaTarget)
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  test('hides the composer while a read-only History topic is selected', () => {
    controller.canComment = true
    controller.readOnlyTopic = false
    controller.updateFormVisibility()
    expect(controller.formTarget.style.display).toBe('')

    controller.handleTopicChange({
      detail: { topicId: '99', readOnly: true, isInbox: false },
    })

    expect(controller.formTarget.style.display).toBe('none')
    expect(controller.shouldAutoFocusOnOpen()).toBe(false)
  })
})
