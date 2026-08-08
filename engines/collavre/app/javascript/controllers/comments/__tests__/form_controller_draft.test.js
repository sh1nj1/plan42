/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import FormController from '../form_controller'
import chatDrafts from '../../../lib/chat_drafts'

describe('FormController - draft persistence', () => {
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

  const dispatchTopicChange = (effectiveCreativeId, topicId = '10073') => {
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
    document.body.dataset.currentUserId = '9'

    if (typeof global.requestAnimationFrame !== 'function') {
      global.requestAnimationFrame = (cb) => setTimeout(cb, 0)
    }
    if (!global.DataTransfer) {
      global.DataTransfer = class {
        constructor() {
          this.files = []
          this.items = { add: (file) => this.files.push(file) }
        }
      }
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
    controller.creativeId = '77'
  })

  afterEach(() => {
    application.stop()
    document.body.removeChild(container)
    document.head.querySelector('meta[name="csrf-token"]').remove()
    delete document.body.dataset.currentUserId
    jest.restoreAllMocks()
  })

  test('restores a saved draft when the popup opens for that chat', () => {
    chatDrafts.set('77', 'unfinished thought')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('unfinished thought')
  })

  test('does not clobber a non-empty textarea on restore', () => {
    chatDrafts.set('77', 'stored draft')
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'already typing'
    controller._restoreDraft()
    expect(controller.textareaTarget.value).toBe('already typing')
  })

  test('typing saves the draft after the 500ms debounce', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'saving me')
    expect(chatDrafts.get('77')).toBeNull()
    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(chatDrafts.get('77')).toBe('saving me')
  })

  test('switching to another chat flush-saves the previous draft under the previous key', () => {
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'draft for 77'
    dispatchTopicChange('88')
    expect(chatDrafts.get('77')).toBe('draft for 77')
    controller.onPopupOpened({ creativeId: '88', canComment: true })
    expect(controller.textareaTarget.value).toBe('')
  })

  test('switching topics within the same chat does not flush the draft', () => {
    dispatchTopicChange('77', '10073')
    controller.textareaTarget.value = 'still composing'
    dispatchTopicChange('77', '10074')
    expect(chatDrafts.get('77')).toBeNull()
    expect(controller._activeDraftKey).toBe('77')
  })

  test('switching linked creatives flushes before resetting a shared effective draft', () => {
    popupEl.dataset.creativeId = '77'
    dispatchTopicChange('70', '10073')
    typeInto(controller.textareaTarget, 'draft from linked creative 77')

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70', '10073')

    expect(chatDrafts.get('70')).toBe('draft from linked creative 77')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    expect(controller.textareaTarget.value).toBe('draft from linked creative 77')
  })

  test('falls back to the raw creative id until an effective id is available', () => {
    delete popupEl.dataset.effectiveCreativeId
    popupEl.dataset.creativeId = '66'
    popupEl.dispatchEvent(
      new CustomEvent('comments--topics:change', { detail: { topicId: '10073' } }),
    )
    expect(controller._activeDraftKey).toBe('66')
  })

  test('keeps the draft key empty when no creative id is available', () => {
    delete popupEl.dataset.effectiveCreativeId
    delete popupEl.dataset.creativeId
    popupEl.dispatchEvent(
      new CustomEvent('comments--topics:change', { detail: { topicId: '10073' } }),
    )
    expect(controller._activeDraftKey).toBeNull()
  })

  test('closing the popup flush-saves the draft; blank input deletes it', () => {
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'saved on close'
    controller.onPopupClosed()
    expect(chatDrafts.get('77')).toBe('saved on close')

    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('saved on close')
    controller.textareaTarget.value = ''
    controller.onPopupClosed()
    expect(chatDrafts.get('77')).toBeNull()
  })

  test('disconnect (Turbo navigation) flush-saves the draft', () => {
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'leaving the page'
    controller.disconnect()
    expect(chatDrafts.get('77')).toBe('leaving the page')
    controller.connect()
  })

  test('discarding drafts cancels a pending save and prevents disconnect from recreating it', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'must be discarded')

    controller.discardDraft()
    controller.disconnect()
    await new Promise((resolve) => setTimeout(resolve, 600))

    expect(chatDrafts.get('77')).toBeNull()
    controller.connect()
  })

  test('losing comment permission flush-saves the draft', () => {
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'permission changed'
    controller.setCommentPermission(false)
    expect(chatDrafts.get('77')).toBe('permission changed')
    controller.setCommentPermission(true)
    expect(controller.formTarget.style.display).toBe('')
  })

  test('successful send clears the stored draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'about to send')
    controller._flushDraftSave()
    expect(chatDrafts.get('77')).toBe('about to send')

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.textareaTarget.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }),
    )
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(chatDrafts.get('77')).toBeNull()
    expect(controller.textareaTarget.value).toBe('')
  })

  test('successful send preserves newer text entered while the request is in flight', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'first message')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    typeInto(controller.textareaTarget, 'next message')
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('next message')
    expect(chatDrafts.get('77')).toBe('next message')
  })

  test('failed send keeps the stored draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'will fail')
    controller._flushDraftSave()

    global.fetch = jest.fn(() =>
      Promise.resolve({
        ok: false,
        status: 500,
        json: () => Promise.resolve({ errors: ['boom'] }),
      }),
    )
    controller.textareaTarget.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }),
    )
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(chatDrafts.get('77')).toBe('will fail')
  })

  test('send completion after a chat switch clears only the submitted chat draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'send from 77')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })
    typeInto(controller.textareaTarget, 'draft for 88')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBeNull()
    expect(chatDrafts.get('88')).toBe('draft for 88')
    expect(controller.textareaTarget.value).toBe('draft for 88')
  })

  test('editing a comment preserves the draft and suspends draft saving', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my draft')
    controller.startEditing({ id: 5, content: 'existing comment', private: false })
    expect(chatDrafts.get('77')).toBe('my draft')

    typeInto(controller.textareaTarget, 'existing comment edited')
    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(chatDrafts.get('77')).toBe('my draft')

    controller.handleCancel(new Event('click'))
    expect(controller.textareaTarget.value).toBe('my draft')
  })

  test('successful edit restores the unsent draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my draft')
    controller.startEditing({ id: 5, content: 'existing comment', private: false })
    jest.spyOn(controller, 'renderCommentHtml').mockImplementation(() => {})
    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )

    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('my draft')
    expect(chatDrafts.get('77')).toBe('my draft')
  })

  test('edit completion after a chat switch preserves the submitted chat draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my draft')
    controller.startEditing({ id: 5, content: 'existing comment', private: false })
    jest.spyOn(controller, 'renderCommentHtml').mockImplementation(() => {})

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })
    typeInto(controller.textareaTarget, 'draft for 88')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('my draft')
    expect(chatDrafts.get('88')).toBe('draft for 88')
    expect(controller.textareaTarget.value).toBe('draft for 88')
  })

  test('a stashed slash-command draft is never replaced by the command text', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my draft')
    controller.handleStashDraft(
      new CustomEvent('comments--form:stash-draft', { detail: { draft: 'my draft' } }),
    )
    expect(chatDrafts.get('77')).toBe('my draft')

    typeInto(controller.textareaTarget, '/calendar 2026-08-14')
    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(chatDrafts.get('77')).toBe('my draft')

    controller._restoreStashedDraft('/calendar 2026-08-14')
    expect(controller.textareaTarget.value).toBe('my draft')
    expect(chatDrafts.get('77')).toBe('my draft')
  })

  test('typing without an active draft key does not write to storage', async () => {
    typeInto(controller.textareaTarget, 'orphan text')
    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })
})
