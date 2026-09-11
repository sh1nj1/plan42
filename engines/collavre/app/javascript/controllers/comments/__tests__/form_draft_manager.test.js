/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import FormDraftManager from '../form_draft_manager'
import chatDrafts from '../../../lib/chat_drafts'

// The draft lifecycle was extracted out of comments--form so it can be
// exercised without Stimulus. These tests drive it through a plain host object
// that offers only the form surface the manager is allowed to touch, which is
// what keeps the seam honest: anything the manager reaches for that is not
// listed here shows up as a failure rather than as accidental coupling.
const buildManager = () => {
  document.body.innerHTML = '<div id="host"><textarea></textarea></div>'
  const element = document.getElementById('host')
  const textarea = element.querySelector('textarea')
  const host = {
    element,
    textareaTarget: textarea,
    editingId: null,
    creativeId: null,
    _reviewStore: { isEmpty: true },
    _autoResize: jest.fn(),
    _updateSubmitButton: jest.fn(),
    resetForm: jest.fn(() => { textarea.value = '' }),
  }

  return { host, element, textarea, manager: new FormDraftManager(host) }
}

describe('FormDraftManager', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    document.body.dataset.currentUserId = '9'
    if (typeof global.requestAnimationFrame !== 'function') {
      global.requestAnimationFrame = (cb) => setTimeout(cb, 0)
    }
  })

  test('debounce-saves typed input under the active chat key', () => {
    jest.useFakeTimers()
    try {
      const { manager, textarea } = buildManager()
      manager.connect()
      manager._activeDraftKey = '42'

      textarea.value = 'roadmap notes'
      textarea.dispatchEvent(new Event('input', { bubbles: true }))
      expect(chatDrafts.get('42')).toBeNull()

      jest.advanceTimersByTime(500)
      expect(chatDrafts.get('42')).toBe('roadmap notes')
    } finally {
      jest.useRealTimers()
    }
  })

  test('restores the stored draft when its chat opens', () => {
    chatDrafts.set('42', 'roadmap notes')
    const { manager, textarea, host } = buildManager()
    manager.connect()

    manager.onChatWillOpen({ creativeId: '42' })

    expect(textarea.value).toBe('roadmap notes')
    expect(host.creativeId).toBe('42')
    expect(manager._activeDraftKey).toBe('42')
    // The topics event has not landed yet, so the raw id is still provisional.
    expect(manager._awaitingEffectiveDraftKeyFor).toBe('42')
  })

  test('re-opening the chat it already owns leaves the in-progress text alone', () => {
    const { manager, textarea, host } = buildManager()
    manager.connect()
    manager.onChatWillOpen({ creativeId: '42' })
    host.resetForm.mockClear()

    textarea.value = 'half-typed reply'
    manager.onChatWillOpen({ creativeId: 42 })

    // resetForm would have wiped the textarea; the repeat open must be a no-op.
    expect(host.resetForm).not.toHaveBeenCalled()
    expect(textarea.value).toBe('half-typed reply')
  })

  test('discarding a draft cancels the pending save instead of writing it back', () => {
    jest.useFakeTimers()
    try {
      const { manager, textarea } = buildManager()
      manager.connect()
      manager._activeDraftKey = '42'

      textarea.value = 'roadmap notes'
      textarea.dispatchEvent(new Event('input', { bubbles: true }))
      manager.discardDraft()
      jest.advanceTimersByTime(500)

      expect(chatDrafts.get('42')).toBeNull()
      expect(manager._activeDraftKey).toBeNull()
    } finally {
      jest.useRealTimers()
    }
  })

  test('disconnecting stops the textarea from feeding further saves', () => {
    jest.useFakeTimers()
    try {
      const { manager, textarea } = buildManager()
      manager.connect()
      manager._activeDraftKey = '42'
      manager.disconnect()

      textarea.value = 'typed after teardown'
      textarea.dispatchEvent(new Event('input', { bubbles: true }))
      jest.advanceTimersByTime(500)

      expect(chatDrafts.get('42')).toBeNull()
    } finally {
      jest.useRealTimers()
    }
  })

  test('a partial key migration only tracks the plain draft that was sent', () => {
    const { manager } = buildManager()
    manager.connect()
    const namespace = chatDrafts.namespace()
    const sourceDraft = { text: 'roadmap notes', revision: 3, updatedAt: 10 }
    const targetDraft = { text: 'roadmap notes', revision: 3, updatedAt: 10 }
    const plainSubmission = {
      namespace,
      key: '42',
      storedRevision: 3,
      migratedSources: [],
    }
    // A stashed command carries text the user never meant to keep as a draft,
    // so the migration must not adopt the new key on its behalf.
    const stashedSubmission = {
      namespace,
      key: '42',
      storedRevision: 3,
      hadStash: true,
      migratedSources: [],
    }
    manager._pendingDraftSubmissions.add(plainSubmission)
    manager._pendingDraftSubmissions.add(stashedSubmission)

    manager._trackPartialDraftMigration('42', '77', sourceDraft, targetDraft)

    expect(plainSubmission.migratedSources).toEqual([{ key: '77', revision: 3 }])
    expect(stashedSubmission.migratedSources).toEqual([])
  })
})
