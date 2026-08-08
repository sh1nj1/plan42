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

  const dismissAlert = () => {
    document.querySelector('.modal-dialog-btn-primary')?.click()
  }

  const submissionBackup = (chatId) => (
    chatDrafts.latestSubmissionBackup(chatId)?.text || null
  )

  beforeEach(async () => {
    window.localStorage.clear()
    window.sessionStorage.clear()
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

  test('a failed in-flight send cannot recreate a draft after cross-tab logout', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'old user submission')
    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    window.dispatchEvent(new StorageEvent('storage', {
      key: 'collavre_chat_drafts_clear',
      newValue: JSON.stringify({
        namespace: 'collavre_chat_drafts_9',
        nonce: 'another-tab-logout',
      }),
    }))
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('')

    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('77')).toBeNull()
    expect(controller.sending).toBe(false)
    dismissAlert()
  })

  test('an invalidated send success does not reset input entered after logout', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'old user submission')
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    window.dispatchEvent(new StorageEvent('storage', {
      key: 'collavre_chat_drafts_clear',
      newValue: JSON.stringify({
        namespace: 'collavre_chat_drafts_9',
        nonce: 'another-tab-logout',
      }),
    }))
    document.body.dataset.currentUserId = '10'
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'new input after logout')
    controller._flushDraftSave()

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('new input after logout')
    expect(chatDrafts.get('77')).toBe('new input after logout')
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

  test('same-tab logout invalidates an in-flight send before clearing drafts', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'old user submission')
    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.discardDraft()
    chatDrafts.clearAll()
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBeNull()
    expect(submissionBackup('77')).toBeNull()
    expect(controller.textareaTarget.value).toBe('')
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

  test('permission loss preserves an undebounced submission when the send fails', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'submission before permission loss')
    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.setCommentPermission(false)
    expect(chatDrafts.get('77')).toBeNull()
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBeNull()
    expect(submissionBackup('77')).toBe('submission before permission loss')
    controller.setCommentPermission(true)
    expect(controller.textareaTarget.value).toBe('submission before permission loss')
    dismissAlert()
  })

  test('permission loss preserves text entered after an in-flight submission', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'first submitted message')
    controller._flushDraftSave()
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    typeInto(controller.textareaTarget, 'next message before permission loss')
    controller.setCommentPermission(false)
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('next message before permission loss')
    controller.setCommentPermission(true)
    expect(controller.textareaTarget.value).toBe('next message before permission loss')
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

  test('submission debounce does not overwrite a newer draft from another tab', async () => {
    chatDrafts.set('77', 'shared starting draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'message submitted from this tab')
    chatDrafts.set('77', 'newer draft from another tab')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    expect(chatDrafts.get('77')).toBe('newer draft from another tab')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('newer draft from another tab')
    expect(chatDrafts.get('77')).toBe('newer draft from another tab')
  })

  test('submission debounce preserves a same-text revision from another tab', async () => {
    chatDrafts.set('77', 'shared starting draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'message submitted from this tab')
    chatDrafts.set('77', 'other tab temporary change')
    chatDrafts.set('77', 'shared starting draft')

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('shared starting draft')
    expect(chatDrafts.get('77')).toBe('shared starting draft')
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

  test('successful slow send does not restore the submitted text when its debounce fires', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'message sent before debounce')
    const saveDraft = jest.spyOn(chatDrafts, 'set')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    await new Promise((resolve) => setTimeout(resolve, 600))
    expect(saveDraft).not.toHaveBeenCalled()
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
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
    controller.resetForm()
    controller._restoreDraft()

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('user 10 draft')
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

  test('failed send persists input submitted before its debounce runs', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'unsaved message that will fail')

    const failedResponse = {
      ok: false, status: 500, json: () => Promise.resolve({ errors: ['boom'] }),
    }
    global.fetch = jest.fn(() => Promise.resolve(failedResponse))
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(submissionBackup('77')).toBe('unsaved message that will fail')
  })

  test('failed send replaces an older restored backup with the submitted text', async () => {
    chatDrafts.saveSubmissionBackup('77', 'older failed submission')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'new submission that will fail')

    const failedResponse = {
      ok: false, status: 500, json: () => Promise.resolve({ errors: ['boom'] }),
    }
    global.fetch = jest.fn(() => Promise.resolve(failedResponse))
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(submissionBackup('77')).toBe('new submission that will fail')
    dismissAlert()

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))
    controller.resetForm()
    controller._restoreDraft()

    expect(submissionBackup('77')).toBeNull()
    expect(controller.textareaTarget.value).toBe('')
  })

  test('failed send persists unsaved input after switching chats', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'unsaved message from 77')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.onChatWillOpen({ creativeId: '88' })
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(submissionBackup('77')).toBe('unsaved message from 77')
    expect(controller.textareaTarget.value).toBe('')
  })

  test('restores a failed submission newer than an existing stored draft', async () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    chatDrafts.set('77', 'older stored draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'newer failed submission')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.onChatWillOpen({ creativeId: '88' })
    popupEl.dataset.creativeId = '88'
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    Date.now.mockReturnValue(2000)
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('older stored draft')
    expect(submissionBackup('77')).toBe('newer failed submission')

    controller.onChatWillOpen({ creativeId: '77' })
    popupEl.dataset.creativeId = '77'
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('newer failed submission')

    Date.now.mockReturnValue(3000)
    chatDrafts.set('77', 'newest draft from another tab')
    controller.onPopupClosed()

    expect(chatDrafts.get('77')).toBe('newest draft from another tab')
  })

  test('failed send preserves newer text saved after the submission started', async () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    chatDrafts.set('77', 'older stored draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'submitted message that will fail')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    Date.now.mockReturnValue(2000)
    typeInto(controller.textareaTarget, 'newer message after submission')
    controller.onChatWillOpen({ creativeId: '88' })
    popupEl.dataset.creativeId = '88'
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    Date.now.mockReturnValue(3000)
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('newer message after submission')
    expect(submissionBackup('77')).toBeNull()

    controller.onChatWillOpen({ creativeId: '77' })
    popupEl.dataset.creativeId = '77'
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('newer message after submission')
  })

  test('failed send preserves a cross-tab draft saved after submission', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'submitted message that will fail')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    chatDrafts.set('77', 'newer draft from another tab')
    controller.onChatWillOpen({ creativeId: '88' })
    popupEl.dataset.creativeId = '88'
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('newer draft from another tab')
    expect(submissionBackup('77')).toBeNull()

    controller.onChatWillOpen({ creativeId: '77' })
    popupEl.dataset.creativeId = '77'
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('newer draft from another tab')
  })

  test('failed send respects a cross-tab clear after submission', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'submitted message that will fail')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    chatDrafts.set('77', 'temporary draft from another tab')
    chatDrafts.clear('77')
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBeNull()
    expect(submissionBackup('77')).toBeNull()
  })

  test('failure backup keeps submission-time ordering across a late cross-tab write', async () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'submitted message that will fail')

    const saveSubmissionBackup = chatDrafts.saveSubmissionBackup.bind(chatDrafts)
    jest.spyOn(chatDrafts, 'saveSubmissionBackup').mockImplementation((...args) => {
      chatDrafts.set('77', 'draft written during failure handling')
      return saveSubmissionBackup(...args)
    })
    global.fetch = jest.fn(() => Promise.resolve({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    controller.resetForm()
    controller._restoreDraft()

    expect(controller.textareaTarget.value).toBe('draft written during failure handling')
    expect(chatDrafts.get('77')).toBe('draft written during failure handling')
    expect(submissionBackup('77')).toBeNull()
  })

  test('failed send does not mask a cross-tab draft observed at submission', async () => {
    chatDrafts.set('77', 'shared starting draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'stale submitted message')
    chatDrafts.set('77', 'draft from another tab before submission')

    global.fetch = jest.fn(() => Promise.resolve({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('draft from another tab before submission')
    expect(submissionBackup('77')).toBeNull()

    controller.resetForm()
    controller._restoreDraft()

    expect(controller.textareaTarget.value).toBe('draft from another tab before submission')
  })

  test('restores a regular draft newer than a failed-submission backup', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    chatDrafts.saveSubmissionBackup('77', 'older failed submission')
    Date.now.mockReturnValue(2000)
    chatDrafts.set('77', 'newer stored draft')

    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('newer stored draft')
    expect(submissionBackup('77')).toBeNull()
  })

  test('prefers a regular draft saved after a backup at the same timestamp', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    chatDrafts.saveSubmissionBackup('77', 'failed submission')
    chatDrafts.set('77', 'later regular draft')

    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('later regular draft')
    expect(submissionBackup('77')).toBeNull()
  })

  test('does not restore a backup older than a regular draft clear', () => {
    jest.spyOn(Date, 'now').mockReturnValue(500)
    chatDrafts.set('77', 'regular draft')
    Date.now.mockReturnValue(1000)
    chatDrafts.saveSubmissionBackup('77', 'failed submission')
    Date.now.mockReturnValue(2000)
    chatDrafts.clear('77')

    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('')
    expect(submissionBackup('77')).toBeNull()
  })

  test('prefers a same-timestamp regular clear saved after a backup', () => {
    jest.spyOn(Date, 'now').mockReturnValue(1000)
    chatDrafts.set('77', 'regular draft')
    chatDrafts.saveSubmissionBackup('77', 'failed submission')
    chatDrafts.clear('77')

    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })

    expect(controller.textareaTarget.value).toBe('')
    expect(submissionBackup('77')).toBeNull()
  })

  test('pagehide does not persist an uncertain in-flight submission', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'message leaving with the page')
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    window.dispatchEvent(new PageTransitionEvent('pagehide'))

    expect(chatDrafts.get('77')).toBeNull()
    expect(submissionBackup('77')).toBeNull()
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(chatDrafts.get('77')).toBeNull()
    expect(submissionBackup('77')).toBeNull()
  })

  test('sending a restored submission backup clears its exact backup key', async () => {
    chatDrafts.saveSubmissionBackup('77', 'restored submission')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('restored submission')

    global.fetch = jest.fn(() =>
      Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') }),
    )
    controller.handleSend(new Event('submit', { cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(submissionBackup('77')).toBeNull()
  })

  test('clearing a restored submission backup removes it permanently', () => {
    chatDrafts.saveSubmissionBackup('77', 'failed submission to clear')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('failed submission to clear')

    typeInto(controller.textareaTarget, '')
    controller._flushDraftSave()
    controller.resetForm()
    controller._restoreDraft()

    expect(submissionBackup('77')).toBeNull()
    expect(controller.textareaTarget.value).toBe('')
  })

  test('pagehide does not claim a same-text draft saved by another tab', async () => {
    chatDrafts.set('77', 'starting draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'same submitted and external text')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    chatDrafts.set('77', 'same submitted and external text')
    const externalRevision = chatDrafts.revision('77')

    window.dispatchEvent(new PageTransitionEvent('pagehide'))
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.revision('77')).toBe(externalRevision)
    expect(chatDrafts.get('77')).toBe('same submitted and external text')
    expect(controller.textareaTarget.value).toBe('same submitted and external text')
  })

  test('pagehide does not overwrite a different draft saved by another tab', async () => {
    chatDrafts.set('77', 'starting draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'submitted from this tab')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    chatDrafts.set('77', 'different draft from another tab')
    const externalRevision = chatDrafts.revision('77')

    window.dispatchEvent(new PageTransitionEvent('pagehide'))
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.revision('77')).toBe(externalRevision)
    expect(chatDrafts.get('77')).toBe('different draft from another tab')
    expect(controller.textareaTarget.value).toBe('different draft from another tab')
  })

  test('successful send clears its restored backup after the user namespace changes', async () => {
    const backupKey = chatDrafts.saveSubmissionBackup('77', 'old user submission')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    document.body.dataset.currentUserId = '10'
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(window.sessionStorage.getItem(backupKey)).toBeNull()
  })

  test('pagehide preserves an external draft detected when submission starts', async () => {
    chatDrafts.set('77', 'starting draft')
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    typeInto(controller.textareaTarget, 'submitted from this tab')
    chatDrafts.set('77', 'external draft present before submit')
    const externalRevision = chatDrafts.revision('77')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))
    window.dispatchEvent(new PageTransitionEvent('pagehide'))
    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.revision('77')).toBe(externalRevision)
    expect(chatDrafts.get('77')).toBe('external draft present before submit')
    expect(controller.textareaTarget.value).toBe('external draft present before submit')
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

  test('linked-key migration rekeys a restored submission backup in flight', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    chatDrafts.saveSubmissionBackup('78', 'failed submission before linked topics resolve')
    controller.resetForm()
    controller._restoreDraft()

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    expect(submissionBackup('78')).toBeNull()
    expect(submissionBackup('70')).toBe('failed submission before linked topics resolve')

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('')
    expect(submissionBackup('70')).toBeNull()
  })

  test('linked-key migration moves a persisted backup without in-memory submission state', () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    chatDrafts.saveSubmissionBackup('78', 'failed submission restored after reload')
    controller._pendingDraftSubmissions.clear()
    controller.resetForm()
    controller._restoreDraft()

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(submissionBackup('78')).toBeNull()
    expect(submissionBackup('70')).toBe('failed submission restored after reload')
    expect(controller.textareaTarget.value).toBe('failed submission restored after reload')
  })

  test('failed send restores an undebounced submission after linked-key migration', async () => {
    delete popupEl.dataset.effectiveCreativeId
    controller.onChatWillOpen({ creativeId: '78' })
    typeInto(controller.textareaTarget, 'failed send before linked topics resolve')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(controller.textareaTarget.value).toBe('failed send before linked topics resolve')
    expect(chatDrafts.get('78')).toBeNull()
    expect(submissionBackup('70')).toBe('failed send before linked topics resolve')
  })

  test('failed linked send restores an edit of the migrated raw baseline', async () => {
    delete popupEl.dataset.effectiveCreativeId
    chatDrafts.set('78', 'stored raw baseline')
    controller.onChatWillOpen({ creativeId: '78' })
    expect(controller.textareaTarget.value).toBe('stored raw baseline')
    typeInto(controller.textareaTarget, 'edited submission before debounce')

    let failFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { failFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })
    failFetch({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ errors: ['boom'] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))

    controller.resetForm()
    controller._restoreDraft()

    expect(controller.textareaTarget.value).toBe('edited submission before debounce')
    expect(submissionBackup('70')).toBe('edited submission before debounce')
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

  test('an incomplete raw-to-effective move keeps the latest raw draft active', () => {
    delete popupEl.dataset.effectiveCreativeId
    chatDrafts.set('78', 'latest raw draft')
    controller.onChatWillOpen({ creativeId: '78' })
    jest.spyOn(chatDrafts, 'move').mockReturnValueOnce(false)

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(controller._activeDraftKey).toBe('78')
    expect(controller._awaitingEffectiveDraftKeyFor).toBe('78')
    expect(controller.textareaTarget.value).toBe('latest raw draft')

    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(controller._activeDraftKey).toBe('70')
    expect(controller._awaitingEffectiveDraftKeyFor).toBeNull()
    expect(controller.textareaTarget.value).toBe('latest raw draft')
    expect(chatDrafts.get('78')).toBeNull()
    expect(chatDrafts.get('70')).toBe('latest raw draft')
  })

  test('an incomplete move restores a newer canonical draft', () => {
    let now = 1000
    jest.spyOn(Date, 'now').mockImplementation(() => now)
    delete popupEl.dataset.effectiveCreativeId
    chatDrafts.set('78', 'stale raw draft')
    now += 1
    chatDrafts.set('70', 'newer canonical draft')
    controller.onChatWillOpen({ creativeId: '78' })
    jest.spyOn(chatDrafts, 'move').mockReturnValue(false)

    popupEl.dataset.creativeId = '78'
    dispatchTopicChange('70')
    controller.onPopupOpened({ creativeId: '78', canComment: true })

    expect(controller._activeDraftKey).toBe('70')
    expect(controller._awaitingEffectiveDraftKeyFor).toBeNull()
    expect(controller.textareaTarget.value).toBe('newer canonical draft')
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

  test('reconnecting before the submission debounce does not persist the sent message', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'send before debounce and reconnect')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.disconnect()
    controller.connect()
    dispatchTopicChange('77')
    controller.onPopupOpened({ creativeId: '77', canComment: true })
    expect(controller.textareaTarget.value).toBe('send before debounce and reconnect')

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

  test('switching chats while a slash command succeeds preserves its stashed draft', async () => {
    dispatchTopicChange('77')
    typeInto(controller.textareaTarget, 'ordinary draft')
    controller.handleStashDraft(
      new CustomEvent('comments--form:stash-draft', { detail: { draft: 'ordinary draft' } }),
    )
    typeInto(controller.textareaTarget, '/calendar 2026-08-14')

    let finishFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { finishFetch = resolve }))
    controller.handleSend(new Event('submit', { cancelable: true }))

    controller.onChatWillOpen({ creativeId: '88' })
    dispatchTopicChange('88')
    controller.onPopupOpened({ creativeId: '88', canComment: true })

    finishFetch({ ok: true, status: 200, text: () => Promise.resolve('<div></div>') })
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(chatDrafts.get('77')).toBe('ordinary draft')
    expect(controller.textareaTarget.value).toBe('')
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
