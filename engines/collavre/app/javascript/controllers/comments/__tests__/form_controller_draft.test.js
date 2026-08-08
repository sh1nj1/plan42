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

  test('typing during an asynchronous chat switch is saved under the incoming chat', () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'draft for 77')

    controller.onChatWillOpen({ creativeId: '88' })
    typeInto(controller.textareaTarget, 'draft for 88')

    expect(chatDrafts.get('77')).toBe('draft for 77')
    expect(chatDrafts.get('88')).toBeNull()

    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    expect(controller.textareaTarget.value).toBe('draft for 88')
    expect(chatDrafts.get('88')).toBe('draft for 88')
  })

  test('a slash-command stash from the outgoing chat does not suppress the incoming draft', () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'draft for 77')
    controller.handleStashDraft(
      new CustomEvent('comments--form:stash-draft', {
        detail: { draft: 'draft for 77' },
      }),
    )
    controller.textareaTarget.value = '/calendar 2026-08-14 10:00 Sync'

    controller.onChatWillOpen({ creativeId: '88' })
    typeInto(controller.textareaTarget, 'draft for 88')
    controller.onPopupClosed()

    expect(chatDrafts.get('77')).toBe('draft for 77')
    expect(chatDrafts.get('88')).toBe('draft for 88')
  })

  test('typing during a linked chat switch migrates from raw to effective draft key', () => {
    popupEl.dataset.creativeId = '77'
    dispatchTopicChange('70')
    typeInto(controller.textareaTarget, 'shared draft before switch')

    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'shared draft after switch')

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(controller.textareaTarget.value).toBe('shared draft after switch')
    expect(chatDrafts.get('70')).toBe('shared draft after switch')
    expect(chatDrafts.get('78')).toBeNull()
  })

  test('a stale raw linked draft does not replace a newer effective draft', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    chatDrafts.set('78', 'stale raw draft')
    now += 1000
    chatDrafts.set('70', 'new canonical draft')

    controller.onChatWillOpen({ creativeId: '78' })
    expect(controller.textareaTarget.value).toBe('stale raw draft')

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(controller.textareaTarget.value).toBe('new canonical draft')
    expect(chatDrafts.get('70')).toBe('new canonical draft')
    expect(chatDrafts.get('78')).toBeNull()
  })

  test('clearing a raw linked draft removes an older canonical draft', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    chatDrafts.set('70', 'canonical draft')
    now += 1
    chatDrafts.set('78', 'raw draft shown while loading')

    controller.onChatWillOpen({ creativeId: '78' })
    expect(controller.textareaTarget.value).toBe('raw draft shown while loading')

    now += 1
    typeInto(controller.textareaTarget, '')
    controller._flushDraftSave()
    const tombstoneUpdatedAt = chatDrafts.updatedAt('78')
    controller._flushDraftSave()
    expect(chatDrafts.updatedAt('78')).toBe(tombstoneUpdatedAt)

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('70')).toBeNull()
    expect(chatDrafts.get('78')).toBeNull()
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

  test('native pagehide flushes input before the debounce completes', () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'reload-safe draft')

    window.dispatchEvent(new Event('pagehide'))

    expect(chatDrafts.get('77')).toBe('reload-safe draft')
  })

  test('a cross-tab logout discards pending input for the signed-out user', async () => {
    dispatchTopicChange('77')
    chatDrafts.set('88', 'already saved in this tab')
    typeInto(controller.textareaTarget, 'must not return after logout')

    window.dispatchEvent(new StorageEvent('storage', {
      key: 'collavre_chat_drafts_clear',
      newValue: JSON.stringify({
        namespace: 'collavre_chat_drafts_9',
        nonce: 'another-tab-logout',
      }),
    }))
    controller.disconnect()
    await new Promise((resolve) => setTimeout(resolve, 600))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('77')).toBeNull()
    expect(chatDrafts.get('88')).toBeNull()
    controller.connect()
  })

  test('an unrelated storage event leaves the active draft intact', () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'still active')

    window.dispatchEvent(new StorageEvent('storage', {
      key: 'unrelated',
      newValue: 'x',
    }))
    window.dispatchEvent(new Event('pagehide'))

    expect(chatDrafts.get('77')).toBe('still active')
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

  test('losing comment permission preserves the saved draft through close', () => {
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'permission changed'
    controller.setCommentPermission(false)
    expect(chatDrafts.get('77')).toBe('permission changed')

    typeInto(controller.textareaTarget, 'hidden stale text')
    controller.onPopupClosed()
    expect(chatDrafts.get('77')).toBe('permission changed')

    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('permission changed')
  })

  test('regaining comment permission restores the saved draft', () => {
    dispatchTopicChange('77')
    controller.textareaTarget.value = 'permission changed'
    controller.setCommentPermission(false)

    controller.setCommentPermission(true)
    expect(controller.formTarget.style.display).toBe('')
    expect(controller.textareaTarget.value).toBe('permission changed')
  })

  test('opening a read-only chat does not clear its saved draft on close', () => {
    chatDrafts.set('77', 'read-only saved draft')
    dispatchTopicChange('77')

    controller.onPopupOpened({ creativeId: '77', canComment: false })
    controller.onPopupClosed()

    expect(chatDrafts.get('77')).toBe('read-only saved draft')
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

  test('successful send restores a newer stored draft for the active chat', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'first message')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    chatDrafts.set('77', 'draft updated outside this form')
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('draft updated outside this form')
    expect(chatDrafts.get('77')).toBe('draft updated outside this form')
  })

  test('successful send preserves a concurrent draft with the same timestamp', async () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'first message')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    const submittedRevision = chatDrafts.revision('77')
    chatDrafts._append('77', {
      text: 'same-millisecond concurrent draft',
      updatedAt: chatDrafts.updatedAt('77'),
      version: `${submittedRevision}-later`,
    })
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('same-millisecond concurrent draft')
    expect(chatDrafts.get('77')).toBe('same-millisecond concurrent draft')
  })

  test('submission snapshots text and revision before a concurrent draft arrives', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'first message')
    controller._flushDraftSave()

    const originalEntry = chatDrafts._entry.bind(chatDrafts)
    let injectConcurrentDraft = true
    jest.spyOn(chatDrafts, '_entry').mockImplementation((chatId) => {
      const entry = originalEntry(chatId)
      if (injectConcurrentDraft && String(chatId) === '77') {
        injectConcurrentDraft = false
        chatDrafts._append('77', {
          text: 'draft saved concurrently after snapshot',
          updatedAt: entry.updatedAt + 1,
          version: `${entry.version}-concurrent`,
        })
      }
      return entry
    })

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('draft saved concurrently after snapshot')
    expect(chatDrafts.get('77')).toBe('draft saved concurrently after snapshot')
  })

  test('successful send preserves a draft another tab saved before submission', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'stale message in this tab')
    controller._flushDraftSave()

    chatDrafts.set('77', 'newer draft from another tab')

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('newer draft from another tab')
    expect(chatDrafts.get('77')).toBe('newer draft from another tab')
  })

  test('an idle tab does not overwrite a draft changed by another tab on close', () => {
    chatDrafts.set('77', 'draft restored in both tabs')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    chatDrafts.set('77', 'newer draft from another tab')
    controller.onPopupClosed()

    expect(chatDrafts.get('77')).toBe('newer draft from another tab')
  })

  test('local input after another tab change remains eligible to save', () => {
    chatDrafts.set('77', 'draft restored in both tabs')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    chatDrafts.set('77', 'draft from another tab')
    typeInto(controller.textareaTarget, 'new local input')
    controller.onPopupClosed()

    expect(chatDrafts.get('77')).toBe('new local input')
  })

  test('successful send clears this tab draft changed before its debounce runs', async () => {
    chatDrafts.set('77', 'older draft from this tab')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'new message sent immediately')

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('77')).toBeNull()
  })

  test('send completion after an account change does not clear the new user draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'user 9 message')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    document.body.dataset.currentUserId = '10'
    chatDrafts.set('77', 'user 10 draft')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('user 10 draft')
    document.body.dataset.currentUserId = '9'
    expect(chatDrafts.get('77')).toBe('user 9 message')
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

  test('send completion clears a submitted draft after raw-to-effective key migration', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'send before linked topics resolve')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    expect(controller.textareaTarget.value).toBe('send before linked topics resolve')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBeNull()
  })

  test('raw-to-effective migration preserves a newer canonical draft during submission', async () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'stale linked message')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    now += 1000
    chatDrafts.set('70', 'newer canonical draft')
    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('newer canonical draft')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBe('newer canonical draft')
  })

  test('a failed raw-to-effective move keeps the submission bound to the raw key', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'send despite migration failure')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    jest.spyOn(chatDrafts, 'move').mockReturnValue(false)

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBeNull()
  })

  test('send completion clears a target copied before the source marker fails', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'send during partial migration')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    jest.spyOn(chatDrafts, 'move').mockImplementation((sourceKey, targetKey) => {
      chatDrafts._append(String(targetKey), { ...chatDrafts._entry(String(sourceKey)) })
    })

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBeNull()
  })

  test('send completion rebinds when another tab already moved the submitted draft', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'send after another tab migrates')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    chatDrafts.move('78', '70')

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBeNull()
  })

  test('linked-key migration preserves a stashed draft that differs from the command', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'ordinary draft before command')
    controller.handleStashDraft(
      new CustomEvent('comments--form:stash-draft', {
        detail: { draft: 'ordinary draft before command' },
      }),
    )
    typeInto(controller.textareaTarget, '/calendar 2026-08-14')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('ordinary draft before command')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBe('ordinary draft before command')
  })

  test('an unrelated linked-key migration does not rebind a pending submission', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'send from 77')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'draft for linked chat')
    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBeNull()
    expect(chatDrafts.get('70')).toBe('draft for linked chat')
    expect(controller.textareaTarget.value).toBe('draft for linked chat')
  })

  test('typing in another chat does not preserve a restored submitted message', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'send from 77')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.onChatWillOpen({ creativeId: '88' })
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })
    typeInto(controller.textareaTarget, 'draft for 88')

    controller.onChatWillOpen({ creativeId: '77' })
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('send from 77')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('77')).toBeNull()
    expect(chatDrafts.get('88')).toBe('draft for 88')
  })

  test('reconnecting during a send does not preserve the restored submitted message', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'send before reconnect')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.disconnect()
    controller.connect()
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('send before reconnect')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('77')).toBeNull()
  })

  test('reconnecting during a send preserves text typed after the reconnect', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'send before reconnect')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.disconnect()
    controller.connect()
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'next message after reconnect')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('next message after reconnect')
    expect(chatDrafts.get('77')).toBe('next message after reconnect')
  })

  test('reconnecting while linked topics load preserves migration and new input', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'send before reconnect')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.disconnect()
    controller.connect()
    expect(controller._activeDraftKey).toBe('78')
    expect(controller._awaitingEffectiveDraftKeyFor).toBe('78')
    typeInto(controller.textareaTarget, 'next message after reconnect')

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('next message after reconnect')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBe('next message after reconnect')
  })

  test('send completion preserves newer submitted-chat text after switching away', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'first message')
    controller._flushDraftSave()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    typeInto(controller.textareaTarget, 'next message')
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('next message')
    expect(controller.textareaTarget.value).toBe('')
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

  test('a message typed while a slash command is pending is saved on close', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my draft')
    controller.handleStashDraft(
      new CustomEvent('comments--form:stash-draft', { detail: { draft: 'my draft' } }),
    )
    typeInto(controller.textareaTarget, '/calendar 2026-08-14')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    typeInto(controller.textareaTarget, 'next message')
    controller.onPopupClosed()
    const savedOnClose = chatDrafts.get('77')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(savedOnClose).toBe('next message')
    expect(chatDrafts.get('77')).toBe('next message')
  })

  test('review quote feedback never replaces the ordinary chat draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my ordinary draft')

    controller.appendReviewQuote(5, 'quoted review text')
    typeInto(controller.textareaTarget, 'feedback for the quote')
    await new Promise((resolve) => setTimeout(resolve, 600))

    expect(chatDrafts.get('77')).toBe('my ordinary draft')

    controller.onPopupClosed()
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('my ordinary draft')
  })

  test('successful review send restores the ordinary chat draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my ordinary draft')
    controller.appendReviewQuote(5, 'quoted review text')
    typeInto(controller.textareaTarget, 'feedback for the quote')
    controller._commitActiveQuote()

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('my ordinary draft')
    expect(chatDrafts.get('77')).toBe('my ordinary draft')
  })

  test('removing the last review quote restores the ordinary chat draft', () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my ordinary draft')
    controller.appendReviewQuote(5, 'quoted review text')
    typeInto(controller.textareaTarget, 'feedback for the quote')

    controller.reviewQuotesContainerTarget
      .querySelector('.review-quote-chip-remove')
      .click()

    expect(controller.textareaTarget.value).toBe('my ordinary draft')
    expect(chatDrafts.get('77')).toBe('my ordinary draft')
  })

  test('sending the last question quote restores the ordinary chat draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'my ordinary draft')
    controller.appendReviewQuote(5, 'quoted question text')
    controller._reviewStore.toggleType(controller._reviewStore.activeId)
    typeInto(controller.textareaTarget, 'question feedback')
    jest.spyOn(controller, 'renderCommentHtml').mockImplementation(() => {})
    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )

    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('my ordinary draft')
    expect(chatDrafts.get('77')).toBe('my ordinary draft')
  })

  test('typing without an active draft key does not write to storage', async () => {
    typeInto(controller.textareaTarget, 'orphan text')
    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(window.localStorage.getItem('collavre_chat_drafts_9')).toBeNull()
  })
})
