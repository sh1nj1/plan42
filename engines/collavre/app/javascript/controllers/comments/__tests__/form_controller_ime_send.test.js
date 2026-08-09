/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import FormController from '../form_controller'
import chatDrafts from '../../../lib/chat_drafts'

describe('FormController - IME composition send', () => {
  let application
  let container
  let controller
  let popupEl

  const FIXTURE = `
    <div id="comments-popup"
         data-controller="comments--form"
         data-update-comment-text="Update">
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
        <button data-comments--form-target="searchButton" style="display:none;">Search</button>
        <button data-comments--form-target="voiceButton" style="display:none;">Voice</button>
        <input type="file" data-comments--form-target="imageInput" style="display:none;" />
        <button data-comments--form-target="imageButton" style="display:none;">Image</button>
        <div data-comments--form-target="attachmentList"></div>
      </form>
    </div>`

  // Stimulus disconnects a removed controller asynchronously, so a previous
  // test's pending draft flush can land inside a later test's timer wait.
  // Giving each test its own chat id keeps those flushes off our key.
  let chatId
  let nextChatId = 77

  const dispatchTopicChange = (effectiveCreativeId = chatId, topicId = '10073') => {
    popupEl.dataset.effectiveCreativeId = String(effectiveCreativeId)
    popupEl.dispatchEvent(
      new CustomEvent('comments--topics:change', { detail: { topicId } }),
    )
  }

  const typeInto = (textarea, value) => {
    textarea.value = value
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
  }

  beforeEach(async () => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    document.body.dataset.currentUserId = '9'

    if (typeof global.requestAnimationFrame !== 'function') {
      global.requestAnimationFrame = (cb) => setTimeout(cb, 0)
    }
    const meta = document.createElement('meta')
    meta.name = 'csrf-token'
    meta.content = 'test-token'
    document.head.appendChild(meta)

    container = document.createElement('div')
    container.innerHTML = FIXTURE
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--form', FormController)
    await new Promise((resolve) => setTimeout(resolve, 50))
    popupEl = container.querySelector('#comments-popup')
    controller = application.getControllerForElementAndIdentifier(popupEl, 'comments--form')
    jest.spyOn(controller, 'setImageFiles').mockImplementation(() => {})
    chatId = String(nextChatId)
    nextChatId += 1
    controller.creativeId = chatId
  })

  afterEach(() => {
    application.stop()
    document.body.removeChild(container)
    document.head.querySelector('meta[name="csrf-token"]').remove()
    delete document.body.dataset.currentUserId
    jest.restoreAllMocks()
  })

  test('Enter pressed while an IME composition is active does not send', async () => {
    dispatchTopicChange()
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      status: 200,
      text: () => Promise.resolve('<div></div>'),
    }))
    typeInto(controller.textareaTarget, '안녕하세')

    controller.textareaTarget.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      isComposing: true,
      bubbles: true,
      cancelable: true,
    }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(global.fetch).not.toHaveBeenCalled()
    expect(controller.textareaTarget.value).toBe('안녕하세')
  })

  test('an IME commit after send does not restore the sent text into the textarea', async () => {
    dispatchTopicChange()
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))

    typeInto(controller.textareaTarget, '안녕하세요')
    controller.handleSend(new Event('submit', { cancelable: true }))

    // The IME commits the pending syllable right after keydown started the
    // send. The textarea content is unchanged, but an input event still fires.
    controller.textareaTarget.dispatchEvent(new Event('input', { bubbles: true }))

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get(chatId)).toBeNull()
  })

  test('a slow send does not let the IME commit debounce the sent text into storage', async () => {
    dispatchTopicChange()
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))

    typeInto(controller.textareaTarget, '안녕하세요')
    controller.handleSend(new Event('submit', { cancelable: true }))
    controller.textareaTarget.dispatchEvent(new Event('input', { bubbles: true }))

    // The response outlives the 500ms draft debounce window.
    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(chatDrafts.get(chatId)).toBeNull()

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get(chatId)).toBeNull()
  })

  test('Enter after the composition ends still sends', async () => {
    dispatchTopicChange()
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true,
      status: 200,
      text: () => Promise.resolve('<div></div>'),
    }))
    typeInto(controller.textareaTarget, '안녕하세요')

    controller.textareaTarget.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      isComposing: false,
      bubbles: true,
      cancelable: true,
    }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(global.fetch).toHaveBeenCalled()
    expect(controller.textareaTarget.value).toBe('')
  })

  test('text genuinely typed during the send is still preserved', async () => {
    dispatchTopicChange()
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))

    typeInto(controller.textareaTarget, 'first message')
    controller.handleSend(new Event('submit', { cancelable: true }))
    typeInto(controller.textareaTarget, 'typed while sending')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('typed while sending')
    expect(chatDrafts.get(chatId)).toBe('typed while sending')
  })
})
