import { Controller } from '@hotwired/stimulus'
import { renderMarkdownInContainer } from '../../lib/utils/markdown'
import { wrapHtmlInCodeBlocks } from '../../lib/html_code_block_wrapper'
import { refreshCsrfToken } from '../../lib/api/csrf_fetch'
import ReviewQuotesStore from './review_quotes_store'
import { alertDialog } from '../../lib/utils/dialog'
import chatDrafts from '../../lib/chat_drafts'

// In-flight comment sends, keyed by creative id. This lives at module scope —
// not on the controller instance — so the duplicate-submit guard survives a
// Stimulus reconnect (Turbo morph / re-render) mid-send. The instance-only
// `this.sending` flag is reset by connect() and cannot be relied on alone:
// a reconnect while a slow request is in flight would re-enable sending and let
// an impatient second Enter submit the same comment twice.
const inFlightSends = new Set()
const sendKeyFor = (creativeId) => `creative:${creativeId}`

export default class extends Controller {
  static targets = [
    'form',
    'textarea',
    'submit',
    'privateCheckbox',
    'cancel',
    'searchButton',
    'voiceButton',
    'imageInput',
    'imageButton',
    'attachmentList',
    'quotedCommentId',
    'quotedText',
    'quoteIndicator',
    'quoteIndicatorText',
    'reviewQuotesContainer',
    'quoteCancelButton',
  ]

  connect() {
    this.creativeId = null
    this.editingId = null
    this.sending = false
    this._reviewStore = new ReviewQuotesStore()
    this.cachedImageFiles = null

    this.handleSubmit = this.handleSubmit.bind(this)
    this.handleSend = this.handleSend.bind(this)
    this.defaultSubmitHTML = this.submitTarget.innerHTML
    this.handlePointerSend = this.handlePointerSend.bind(this)
    this.handleTouchSend = this.handleTouchSend.bind(this)
    this.handleCancel = this.handleCancel.bind(this)
    this.handleSearch = this.handleSearch.bind(this)
    this.handleVoiceToggle = this.handleVoiceToggle.bind(this)
    this.handleRecognitionStart = this.handleRecognitionStart.bind(this)
    this.handleRecognitionEnd = this.handleRecognitionEnd.bind(this)
    this.handleRecognitionResult = this.handleRecognitionResult.bind(this)
    this.handleRecognitionError = this.handleRecognitionError.bind(this)
    this.handleImageButtonClick = this.handleImageButtonClick.bind(this)
    this.handleImageChange = this.handleImageChange.bind(this)
    this.handleDragOver = this.handleDragOver.bind(this)
    this.handleDragLeave = this.handleDragLeave.bind(this)
    this.handleDrop = this.handleDrop.bind(this)

    this.formTarget.addEventListener('submit', this.handleSubmit)
    this.submitTarget.addEventListener('click', this.handleSend)
    this.submitTarget.addEventListener('pointerup', this.handlePointerSend)
    this.submitTarget.addEventListener('touchend', this.handleTouchSend, { passive: false })
    this.cancelTarget?.addEventListener('click', this.handleCancel)
    this.searchButtonTarget?.addEventListener('click', this.handleSearch)
    this.voiceButtonTarget?.addEventListener('click', this.handleVoiceToggle)

    this.imageButtonTarget?.addEventListener('click', this.handleImageButtonClick)
    this.imageInputTarget?.addEventListener('change', this.handleImageChange)
    this.formTarget.addEventListener('dragover', this.handleDragOver)
    this.formTarget.addEventListener('dragleave', this.handleDragLeave)
    this.formTarget.addEventListener('drop', this.handleDrop)
    this.handlePaste = this.handlePaste.bind(this)
    this.textareaTarget.addEventListener('paste', this.handlePaste)


    this.recognition = null
    this.listening = false
    this.recognitionActive = false

    // Auto-resize textarea
    this._autoResize = () => {
      const textarea = this.textareaTarget
      textarea.style.height = 'auto'
      const maxHeight = parseInt(getComputedStyle(textarea).lineHeight, 10) * 10 || 200
      textarea.style.height = `${Math.min(textarea.scrollHeight, maxHeight)}px`
    }
    this.textareaTarget.addEventListener('input', this._autoResize)

    // Draft persistence: debounce-save unsent input per chat.
    // _activeDraftKey always identifies the chat whose text is in the textarea.
    this._activeDraftKey ??= null
    this._activeDraftCreativeId ??= null
    this._awaitingEffectiveDraftKeyFor ??= null
    this._draftSaveTimer = null
    this._draftSaveSuspendedForPermission ??= false
    // A pending send survives a Stimulus reconnect on this controller instance,
    // so its completion must keep comparing against the same draft history.
    this._draftRevisions ||= new Map()
    this._observedDrafts ||= new Map()
    this._observedDraftRevisions ||= new Map()
    this._observedStoredDraftRevisions ||= new Map()
    // A linked chat can replace its temporary raw key while its request is in
    // flight. Keep mutable submission state across that migration/reconnect.
    this._pendingDraftSubmissions ||= new Set()
    this._handlePageHide = () => {
      if (!this.element.isConnected) return

      this._flushDraftSave()
    }
    this._handleDraftStorage = (event) => {
      if (!this.element.isConnected || !chatDrafts.wasCleared(event)) return

      const clearedNamespace = chatDrafts.namespace()
      this._pendingDraftSubmissions?.forEach((submission) => {
        if (submission.namespace !== clearedNamespace) return

        submission.invalidated = true
      })
      this.discardDraft()
      // A timer in this tab may have raced with the logout tab's first clear.
      chatDrafts.clearAll({ broadcast: false })
    }
    this._handleDraftInput = () => {
      if (
        this.editingId ||
        this._draftSaveSuspendedForPermission ||
        this._shouldSuppressDraftSaveForStash() ||
        !this._reviewStore.isEmpty ||
        !this._activeDraftKey
      ) return
      const revisionKey = `${chatDrafts.namespace()}:${this._activeDraftKey}`
      this._draftRevisions.set(revisionKey, (this._draftRevisions.get(revisionKey) || 0) + 1)
      clearTimeout(this._draftSaveTimer)
      this._draftSaveTimer = setTimeout(() => this._saveDraftNow(), 500)
    }
    this.textareaTarget.addEventListener('input', this._handleDraftInput)
    window.addEventListener('pagehide', this._handlePageHide)
    window.addEventListener('storage', this._handleDraftStorage)

    this.textareaTarget.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        this.presenceController?.cancelAllAgentTasks()
        return
      }
      if (event.key === 'Enter' && !event.shiftKey) {
        if (this.isMentionMenuVisible()) return
        this.handleSend(event)
      }
    })

    this.updateAttachmentList()

    this.handleTopicChange = this.handleTopicChange.bind(this)
    this.element.addEventListener('comments--topics:change', this.handleTopicChange)

    this.handleListLoaded = () => this._updateInboxReplyMode()
    this.element.addEventListener('comments--list:loaded', this.handleListLoaded)

    // A slash command with an input schema takes over the textarea and submits
    // itself (modules/command_menu.js), so a draft the user had already typed
    // cannot go out with it. The menu hands the draft over here instead of
    // discarding it, and we put it back once the send settles.
    this.handleStashDraft = this.handleStashDraft.bind(this)
    this.element.addEventListener('comments--form:stash-draft', this.handleStashDraft)
  }

  handleTopicChange(event) {
    // This event fires before onPopupOpened during a chat switch, while the
    // textarea still contains the outgoing chat's text. Flush before re-keying.
    const nextDraftKey =
      this.element.dataset.effectiveCreativeId || this.element.dataset.creativeId || null
    const nextCreativeId = this.element.dataset.creativeId || null
    const draftKeyChanged = String(this._activeDraftKey || '') !== String(nextDraftKey || '')
    const creativeChanged =
      String(this._activeDraftCreativeId || '') !== String(nextCreativeId || '')
    const resolvingIncomingDraftKey =
      this._awaitingEffectiveDraftKeyFor &&
      String(this._awaitingEffectiveDraftKeyFor) === String(nextCreativeId || '')
    if (draftKeyChanged || creativeChanged) {
      const previousDraftKey = this._activeDraftKey
      // onChatWillOpen already flushed the outgoing chat. While the effective
      // key is loading, save only actual new input; rewriting a restored raw
      // draft here would make stale text appear newer than the canonical draft.
      if (!resolvingIncomingDraftKey || this._draftSaveTimer) this._flushDraftSave()
      this._activeDraftKey = nextDraftKey ? String(nextDraftKey) : null
      this._activeDraftCreativeId = nextCreativeId ? String(nextCreativeId) : null
      if (
        resolvingIncomingDraftKey &&
        previousDraftKey &&
        this._activeDraftKey
      ) {
        const sourceDraft = chatDrafts.snapshot(previousDraftKey)
        chatDrafts.move(previousDraftKey, this._activeDraftKey)
        const targetDraft = chatDrafts.snapshot(this._activeDraftKey)
        const movedBackups = chatDrafts.moveSubmissionBackups(
          previousDraftKey,
          this._activeDraftKey,
        )
        if (targetDraft.revision || !sourceDraft.revision) {
          this._rebindPendingDraftSubmissions(
            previousDraftKey,
            this._activeDraftKey,
            sourceDraft,
            targetDraft,
            movedBackups,
          )
        }
      }
    }
    if (resolvingIncomingDraftKey) this._awaitingEffectiveDraftKeyFor = null
    this.currentTopicId = event.detail.topicId
    this._isInbox = event.detail.isInbox || false
    this._systemTopicId = event.detail.systemTopicId || null
    this._mainTopicId = event.detail.mainTopicId || null
    this._updateInboxReplyMode()
  }


  isMentionMenuVisible() {
    const menu = document.getElementById('mention-menu')
    const commandMenu = document.getElementById('command-menu')
    return menu?.style.display === 'block' || commandMenu?.style.display === 'block'
  }

  disconnect() {
    this._flushDraftSave()
    this.textareaTarget.removeEventListener('input', this._handleDraftInput)
    window.removeEventListener('pagehide', this._handlePageHide)
    window.removeEventListener('storage', this._handleDraftStorage)
    this.formTarget.removeEventListener('submit', this.handleSubmit)
    this.submitTarget.removeEventListener('click', this.handleSend)
    this.submitTarget.removeEventListener('pointerup', this.handlePointerSend)
    this.submitTarget.removeEventListener('touchend', this.handleTouchSend)
    this.cancelTarget?.removeEventListener('click', this.handleCancel)
    this.searchButtonTarget?.removeEventListener('click', this.handleSearch)
    this.voiceButtonTarget?.removeEventListener('click', this.handleVoiceToggle)
    this.teardownSpeechRecognition()
    this.imageButtonTarget?.removeEventListener('click', this.handleImageButtonClick)
    this.imageInputTarget?.removeEventListener('change', this.handleImageChange)
    this.textareaTarget.removeEventListener('input', this._autoResize)
    this.formTarget.removeEventListener('dragover', this.handleDragOver)
    this.formTarget.removeEventListener('dragleave', this.handleDragLeave)
    this.formTarget.removeEventListener('drop', this.handleDrop)
    this.textareaTarget.removeEventListener('paste', this.handlePaste)
    this.element.removeEventListener('comments--topics:change', this.handleTopicChange)
    this.element.removeEventListener('comments--list:loaded', this.handleListLoaded)
    this.element.removeEventListener('comments--form:stash-draft', this.handleStashDraft)
  }

  get listController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--list')
  }

  get presenceController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'comments--presence')
  }

  onPopupOpened({ creativeId, canComment }) {
    this.creativeId = creativeId
    this.element.dataset.creativeId = creativeId || ''
    if (canComment) this._draftSaveSuspendedForPermission = false
    // Stale topic ids from the previous creative are cleared by the popup
    // controller BEFORE topics loadTopics() dispatches comments--topics:change,
    // so by the time we get here, currentTopicId already reflects the new
    // creative's restored topic. Do not re-clear it.
    this.formTarget.style.display = canComment ? '' : 'none'
    // Capture input entered while topics were loading before reset clears it.
    // Without a pending input timer, a blank textarea must not erase a draft
    // that is waiting in storage to be restored below.
    if (this._draftSaveTimer) this._flushDraftSave()
    this.resetForm()
    this._draftSaveSuspendedForPermission = !canComment
    if (canComment && this.shouldAutoFocusOnOpen()) {
      requestAnimationFrame(() => this.textareaTarget.focus())
    }
    this._restoreDraft()
  }

  onChatWillOpen({ creativeId }) {
    const nextCreativeId = creativeId ? String(creativeId) : null
    if (
      String(this._activeDraftCreativeId || '') === String(nextCreativeId || '')
    ) return

    // The popup publishes its raw creative id before awaiting topics. Flush the
    // outgoing chat now, then give any input typed during that await a key owned
    // by the incoming chat. The topics event replaces it with the effective id.
    this._flushDraftSave()
    this._activeDraftKey = nextCreativeId
    this._activeDraftCreativeId = nextCreativeId
    this._awaitingEffectiveDraftKeyFor = nextCreativeId
    this.creativeId = creativeId
    this.resetForm()
    this._restoreDraft()
  }

  onPopupClosed() {
    this._flushDraftSave()
    this._activeDraftKey = null
    this._activeDraftCreativeId = null
    this._awaitingEffectiveDraftKeyFor = null
    this.stopSpeechRecognition()
    this.resetForm()
  }

  discardDraft() {
    const namespace = chatDrafts.namespace()
    this._pendingDraftSubmissions?.forEach((submission) => {
      if (submission.namespace === namespace) submission.invalidated = true
    })
    clearTimeout(this._draftSaveTimer)
    this._draftSaveTimer = null
    this._activeDraftKey = null
    this._activeDraftCreativeId = null
    this._awaitingEffectiveDraftKeyFor = null
    this._stashedDraft = null
    this.resetForm()
  }

  setCommentPermission(canComment) {
    this.formTarget.style.display = canComment ? '' : 'none'

    if (!canComment) {
      this._flushDraftSave()
      this._draftSaveSuspendedForPermission = true
      this.stopSpeechRecognition()
      this.resetForm()
      return
    }

    this._draftSaveSuspendedForPermission = false
    this._restoreDraft()
    if (this.shouldAutoFocusOnOpen()) {
      requestAnimationFrame(() => this.textareaTarget.focus())
    }
  }

  onSelectionChanged({ size, moving }) {
    // Selection state now managed by list_controller action bar
  }

  shouldAutoFocusOnOpen() {
    if (window.innerWidth <= 768) return false
    return this.element.dataset.autoFocusOnOpen !== 'false'
  }

  focusTextarea() {
    if (this.formTarget.style.display === 'none') return
    requestAnimationFrame(() => this.textareaTarget.focus())
  }

  startEditing({ id, content, private: isPrivate }) {
    this._flushDraftSave()
    this.editingId = id
    this.textareaTarget.value = content || ''
    if (this.privateCheckboxTarget) {
      this.privateCheckboxTarget.checked = !!isPrivate
      this.privateCheckboxTarget.dispatchEvent(new Event('change'))
    }
    this.clearImageAttachments()
    this.submitTarget.textContent = this.element.dataset.updateCommentText
    if (this.cancelTarget) this.cancelTarget.style.display = ''
    requestAnimationFrame(() => this._autoResize())
    this.focusTextarea()
  }

  handleStashDraft(event) {
    const draft = event.detail?.draft || null
    if (draft) this._flushDraftSave()
    // Tagged with the conversation it was typed in: the popup reuses this one
    // controller for every creative, so a stash left over from another one must
    // not be handed back here.
    this._stashedDraft = draft ? { draft, creativeId: this.creativeId } : null
  }

  _stashedDraftBelongsToCurrentCreative() {
    return Boolean(
      this._stashedDraft &&
      String(this._stashedDraft.creativeId) === String(this.creativeId),
    )
  }

  _shouldSuppressDraftSaveForStash() {
    if (!this._stashedDraftBelongsToCurrentCreative()) return false

    // Before handleSend captures the command, the command-menu input event
    // must not replace the stashed ordinary draft. Once the send starts, only
    // the submitted command remains suppressed; later input is a new draft.
    return !this._stashedDraft.submittedText ||
      this.textareaTarget.value === this._stashedDraft.submittedText
  }

  _restoreStashedDraft(submittedText) {
    const stashed = this._stashedDraft
    this._stashedDraft = null
    if (!stashed) return
    // Switching creatives calls onPopupOpened on this same instance (there is
    // no disconnect between conversations), so a send that settles after the
    // switch would drop the previous conversation's draft into the new one.
    // The draft belongs to a conversation that is no longer on screen; discard
    // it rather than misfile it.
    if (String(stashed.creativeId ?? '') !== String(this.creativeId ?? '')) return
    const draft = stashed.draft
    // Two boxes are safe to overwrite: an empty one (the success path runs
    // resetForm) and one still holding exactly what we submitted (the failure
    // path never clears it, so the command text is left sitting there). Any
    // other content is text the user typed while the request was in flight, or
    // a review quote the failure path restored, and must not be clobbered.
    const current = this.textareaTarget.value
    if (current.trim().length > 0 && current !== submittedText) return
    this.textareaTarget.value = draft
    // Resize and re-enable send directly rather than dispatching `input`, which
    // would re-open the command menu for a draft that starts with "/".
    this._autoResize()
    this._updateSubmitButton()
    this._saveDraftNow()
  }

  resetForm() {
    this.formTarget.reset()
    this.editingId = null
    this.submitTarget.innerHTML = this.defaultSubmitHTML
    this.submitTarget.disabled = false
    this.submitTarget.classList.remove('review-submit-btn')
    this.submitTarget.classList.remove('inbox-reply-btn')
    if (this.cancelTarget) this.cancelTarget.style.display = 'none'
    this.presenceController?.clearManualTypingMessage()
    this.clearImageAttachments()
    this.cancelQuote()
    this.textareaTarget.placeholder = this._defaultPlaceholder()
    // Reset textarea height after clearing content
    this.textareaTarget.style.height = 'auto'
  }

  _saveDraftNow() {
    if (
      !this._activeDraftKey ||
      this._draftSaveSuspendedForPermission ||
      this.editingId ||
      this._shouldSuppressDraftSaveForStash() ||
      !this._reviewStore.isEmpty
    ) return
    if (this._currentTextIsPendingSubmission()) return
    const draftKey = this._activeDraftKey
    const text = this.textareaTarget.value
    const blank = !text.trim()
    const preserveBlank = blank && Boolean(this._awaitingEffectiveDraftKeyFor)
    const storedDraft = chatDrafts.snapshot(draftKey)
    const storedText = storedDraft.text
    const hasStoredEntry = chatDrafts.updatedAt(draftKey) !== null
    const observationKey = `${chatDrafts.namespace()}:${draftKey}`
    const hasObservedDraft = this._observedDrafts?.has(observationKey)
    const observedText = this._observedDrafts?.get(observationKey)
    const observedRevision = this._observedDraftRevisions?.get(observationKey) || 0
    const observedStoredRevision =
      this._observedStoredDraftRevisions?.get(observationKey) || null
    const currentRevision = this._draftRevisions?.get(observationKey) || 0
    const draftChangedLocally =
      currentRevision !== observedRevision ||
      (hasObservedDraft && (observedText || '') !== text)
    const storedDraftChangedOutsideController = hasObservedDraft && (
      observedText !== storedText || observedStoredRevision !== storedDraft.revision
    )
    // An idle tab can retain stale restored text after another tab updates the
    // same draft. Closing or switching that idle tab must not write it back.
    if (!draftChangedLocally && storedDraftChangedOutsideController) return
    if (preserveBlank) {
      if (storedText !== null || !hasStoredEntry) {
        chatDrafts.set(draftKey, '', { preserveBlank: true })
      }
    } else if (blank) {
      if (hasStoredEntry) {
        chatDrafts.clear(draftKey)
      }
    } else if (storedText !== text) {
      chatDrafts.set(draftKey, text)
    }
    if (blank && draftChangedLocally) chatDrafts.clearSubmissionBackups(draftKey)
    this._observeDraft(draftKey)
  }

  _flushDraftSave() {
    clearTimeout(this._draftSaveTimer)
    this._draftSaveTimer = null
    this._saveDraftNow()
  }

  _currentTextIsPendingSubmission() {
    return Boolean(this._currentPendingSubmission())
  }

  _currentPendingSubmission() {
    const namespace = chatDrafts.namespace()
    const key = String(this._activeDraftKey || '')

    return [...(this._pendingDraftSubmissions || [])].find((submission) => (
      !submission.invalidated &&
      submission.namespace === namespace &&
      String(submission.key || '') === key &&
      !submission.hadStash &&
      !submission.hadReview &&
      !submission.editing &&
      submission.text === this.textareaTarget.value &&
      (this._draftRevisions?.get(submission.revisionKey) || 0) === submission.keyRevision
    ))
  }

  _restoreDraft() {
    if (!this._activeDraftKey || this.editingId) return
    if (this.textareaTarget.value.trim()) return

    const draft = chatDrafts.snapshot(this._activeDraftKey)
    const backup = draft.text
      ? null
      : chatDrafts.latestSubmissionBackup(this._activeDraftKey)
    this._observeDraft(this._activeDraftKey, draft.text, chatDrafts.namespace(), draft.revision)
    if (draft.text || backup?.text) {
      this.textareaTarget.value = draft.text || backup.text
      requestAnimationFrame(() => this._autoResize())
    } else {
      this._restorePendingSubmittedDraft()
    }
  }

  _restorePendingSubmittedDraft() {
    const namespace = chatDrafts.namespace()
    const pending = [...(this._pendingDraftSubmissions || [])].find((submission) => (
      !submission.invalidated &&
      submission.namespace === namespace &&
      String(submission.key || '') === String(this._activeDraftKey || '') &&
      !submission.hadStash &&
      !submission.hadReview &&
      !submission.editing
    ))
    if (!pending) return

    this.textareaTarget.value = pending.text
    requestAnimationFrame(() => this._autoResize())
    this._updateSubmitButton()
  }

  _observeDraft(
    draftKey,
    text,
    namespace = chatDrafts.namespace(),
    storedRevision,
  ) {
    if (!draftKey) return
    const storedDraft = storedRevision === undefined
      ? chatDrafts.snapshot(draftKey)
      : { text, revision: storedRevision }
    const observationKey = `${namespace}:${draftKey}`
    this._observedDrafts?.set(observationKey, storedDraft.text)
    this._observedDraftRevisions?.set(
      observationKey,
      this._draftRevisions?.get(observationKey) || 0,
    )
    this._observedStoredDraftRevisions?.set(observationKey, storedDraft.revision)
  }

  _rebindPendingDraftSubmissions(
    sourceKey,
    targetKey,
    sourceDraft,
    targetDraft,
    movedBackups = new Map(),
  ) {
    const namespace = chatDrafts.namespace()
    const targetRevisionKey = `${namespace}:${targetKey}`

    this._pendingDraftSubmissions?.forEach((submission) => {
      if (
        submission.namespace !== namespace ||
        String(submission.key) !== String(sourceKey)
      ) return

      const targetMatchesSubmission =
        submission.storedRevision &&
        targetDraft.revision === submission.storedRevision &&
        targetDraft.text === submission.text
      const sourceMatchesSubmission =
        sourceDraft.revision &&
        targetDraft.revision === sourceDraft.revision &&
        targetDraft.text === submission.text
      const submittedDraftWasUnstored =
        !submission.storedRevision &&
        !sourceDraft.revision &&
        !targetDraft.revision
      const submittedDraftWasMoved =
        targetMatchesSubmission || sourceMatchesSubmission || submittedDraftWasUnstored
      if (
        sourceDraft.revision &&
        sourceDraft.text === submission.text
      ) {
        submission.migratedSources.push({
          key: String(sourceKey),
          revision: sourceDraft.revision,
        })
      }
      submission.key = String(targetKey)
      submission.revisionKey = targetRevisionKey
      submission.keyRevision = this._draftRevisions?.get(targetRevisionKey) || 0
      submission.storedRevision = targetDraft.revision
      submission.storedChangedOutsideController ||=
        !submittedDraftWasMoved
      if (submission.backupKey && movedBackups.has(submission.backupKey)) {
        submission.backupKey = movedBackups.get(submission.backupKey)
      }
    })
  }

  _clearMigratedSubmittedSources(submission) {
    submission.migratedSources.forEach(({ key, revision }) => {
      if (chatDrafts.revision(key) !== revision) return

      chatDrafts.clear(key)
      this._observeDraft(key, null, submission.namespace)
    })
  }

  _persistFailedSubmissionDraft(submission) {
    if (
      submission.invalidated ||
      submission.hadStash ||
      submission.hadReview ||
      submission.editing ||
      submission.namespace !== chatDrafts.namespace()
    ) return

    submission.backupKey ||= chatDrafts.saveSubmissionBackup(
      submission.key,
      submission.text,
    )
  }

  setSendingState(isSending) {
    if (!this.submitTarget) return

    if (isSending) {
      this.submitTarget.disabled = true
      return
    }

    this.submitTarget.disabled = false
    this.sending = false
  }

  handleSubmit(event) {
    event.preventDefault()
    this.handleSend(event)
  }

  handleSend(event) {
    event.preventDefault()

    // If active quote exists, handle based on type
    const store = this._reviewStore
    if (store.hasActive && !store.isEmpty) {
      const activeQuote = store.activeQuote
      if (activeQuote && activeQuote.type === 'question') {
        store.saveActiveFeedback(this.textareaTarget.value)
        this._sendQuestionQuote(activeQuote)
        return
      }
      this._commitActiveQuote()
      return
    }

    const hasText = this.textareaTarget.value.trim().length > 0
    const hasQuotes = !store.isEmpty
    const hasImages = this.currentImageFiles().length > 0
    const sendKey = sendKeyFor(this.creativeId)
    if (this.sending || inFlightSends.has(sendKey) || (!hasText && !hasQuotes && !hasImages) || !this.creativeId) return
    inFlightSends.add(sendKey)
    this.sending = true
    this.setSendingState(true)
    this.presenceController?.stoppedTyping()

    // Cancel any pending input debounce before capturing the submission. A
    // write while the request is in flight looks like a newer draft and can
    // restore the already-sent text on success. Failures persist below.
    if (this._draftSaveTimer) {
      clearTimeout(this._draftSaveTimer)
      this._draftSaveTimer = null
    }

    // Build final content from review quotes + user text
    if (hasQuotes) {
      store.backup(this.textareaTarget.value)
      this.textareaTarget.value = store.buildContent(this.textareaTarget.value)
      this._pendingReviewType = 'review'
    }

    const wasPrivate = this.privateCheckboxTarget?.checked ?? false

    // Captured after the review-quote rewrite above, so it is the exact content
    // going to the server. _restoreStashedDraft compares against it to tell a
    // failure that left the command text behind from text typed mid-flight.
    const submittedText = this.textareaTarget.value
    const initialSubmittedDraftKey = this._activeDraftKey
    const submittedDraftNamespace = chatDrafts.namespace()
    const initialSubmittedDraftRevisionKey =
      `${submittedDraftNamespace}:${initialSubmittedDraftKey}`
    const initialSubmittedDraft = chatDrafts.snapshot(initialSubmittedDraftKey)
    const submittedHadStash = this._stashedDraftBelongsToCurrentCreative()
    const submittedBackup = chatDrafts.latestSubmissionBackup(initialSubmittedDraftKey)
    const observedSubmittedText =
      this._observedDrafts?.get(initialSubmittedDraftRevisionKey)
    const observedSubmittedStoredRevision =
      this._observedStoredDraftRevisions?.get(initialSubmittedDraftRevisionKey) || null
    const submittedTextChangedOutsideController =
      observedSubmittedText !== initialSubmittedDraft.text
    const submittedRevisionChangedOutsideController =
      observedSubmittedStoredRevision !== initialSubmittedDraft.revision
    const submittedStoredDraftChangedOutsideController =
      this._observedDrafts?.has(initialSubmittedDraftRevisionKey) &&
      (submittedTextChangedOutsideController || submittedRevisionChangedOutsideController)
    const submittedDraft = {
      key: initialSubmittedDraftKey,
      namespace: submittedDraftNamespace,
      revisionKey: initialSubmittedDraftRevisionKey,
      storedChangedOutsideController: submittedStoredDraftChangedOutsideController,
      keyRevision: this._draftRevisions?.get(initialSubmittedDraftRevisionKey) || 0,
      storedRevision: initialSubmittedDraft.revision,
      text: submittedText,
      hadStash: submittedHadStash,
      backupKey: submittedBackup?.text === submittedText ? submittedBackup.key : null,
      migratedSources: [],
    }
    this._pendingDraftSubmissions ||= new Set()
    this._pendingDraftSubmissions.add(submittedDraft)
    const submittedEditingId = this.editingId
    const submittedHadReview = hasQuotes
    submittedDraft.editing = Boolean(submittedEditingId)
    submittedDraft.hadReview = submittedHadReview
    if (submittedHadStash) {
      this._stashedDraft.submittedText = submittedText
    }

    const formData = new FormData(this.formTarget)
    const effectiveTopicId = this.currentTopicId || this._mainTopicId
    if (effectiveTopicId) {
      formData.append('comment[topic_id]', effectiveTopicId)
    }
    if (this._pendingReviewType) {
      formData.append('comment[review_type]', this._pendingReviewType)
      this._pendingReviewType = null
    }

    let url = `/creatives/${this.creativeId}/comments`
    let method = 'POST'
    if (submittedEditingId) {
      url += `/${submittedEditingId}`
      method = 'PATCH'
    }

    const doFetch = () => fetch(url, {
      method,
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
      body: formData,
    })

    doFetch()
      .then((response) => {
        if (response.ok) return response.text()
        // On 422, the CSRF token may have gone stale (e.g. after an OS
        // window switch).  Refresh the token and retry once before giving up.
        if (response.status === 422 && !this._hasRetried) {
          this._hasRetried = true
          return refreshCsrfToken().then(() => doFetch()).then((retryResp) => {
            if (retryResp.ok) return retryResp.text()
            return retryResp.json().then((json) => {
              throw new Error(json.errors?.join(', ') || 'Unable to save comment')
            })
          })
        }
        return response.json().then((json) => {
          throw new Error(json.errors?.join(', ') || 'Unable to save comment')
        })
      })
      .then((html) => {
        if (submittedDraft.backupKey) {
          chatDrafts.removeSubmissionBackup(
            submittedDraft.backupKey,
            submittedDraft.namespace,
          )
          submittedDraft.backupKey = null
        }
        if (
          submittedDraft.invalidated ||
          submittedDraft.namespace !== chatDrafts.namespace()
        ) return

        const {
          key: submittedDraftKey,
          namespace: submittedDraftNamespace,
          revisionKey: submittedDraftRevisionKey,
          storedChangedOutsideController: submittedStoredDraftChangedOutsideController,
          keyRevision: submittedDraftKeyRevision,
          storedRevision: submittedDraftStoredRevision,
          hadStash: submittedHadStash,
        } = submittedDraft
        const ownsSubmittedDraftNamespace =
          !submittedDraft.invalidated &&
          submittedDraftNamespace === chatDrafts.namespace()
        const switchedChats =
          ownsSubmittedDraftNamespace &&
          submittedDraftKey &&
          this._activeDraftKey &&
          String(submittedDraftKey) !== String(this._activeDraftKey)
        const submittedChatStillActive =
          submittedDraftKey &&
          this._activeDraftKey &&
          String(submittedDraftKey) === String(this._activeDraftKey)
        const hasNewerActiveDraft =
          ownsSubmittedDraftNamespace &&
          !submittedEditingId &&
          !submittedHadReview &&
          submittedChatStillActive &&
          (this._draftRevisions?.get(submittedDraftRevisionKey) || 0) !==
            submittedDraftKeyRevision
        const hasNewerStoredDraft =
          ownsSubmittedDraftNamespace &&
          !submittedEditingId &&
          !submittedHadReview &&
          submittedDraftKey &&
          (
            (this._draftRevisions?.get(submittedDraftRevisionKey) || 0) !==
              submittedDraftKeyRevision ||
            submittedStoredDraftChangedOutsideController ||
            chatDrafts.revision(submittedDraftKey) !== submittedDraftStoredRevision
          )
        const hasNewerDraft = hasNewerActiveDraft || hasNewerStoredDraft
        const newerDraft = hasNewerActiveDraft
          ? (
            this._draftSaveSuspendedForPermission
              ? chatDrafts.get(submittedDraftKey)
              : this.textareaTarget.value
          )
          : null
        if (switchedChats) this._flushDraftSave()
        clearTimeout(this._draftSaveTimer)
        this._draftSaveTimer = null
        this.resetForm()
        if (submittedEditingId) {
          if (ownsSubmittedDraftNamespace) this._restoreDraft()
          // If editing, just replace the item in place
          this.renderCommentHtml(html, { replaceExisting: true })
        } else {
          if (submittedHadReview && ownsSubmittedDraftNamespace) {
            this._restoreDraft()
          } else if (hasNewerActiveDraft) {
            this.textareaTarget.value = newerDraft
            this._autoResize()
            this._updateSubmitButton()
            chatDrafts.set(submittedDraftKey, newerDraft)
            this._observeDraft(submittedDraftKey, newerDraft, submittedDraftNamespace)
          } else if (hasNewerStoredDraft && submittedChatStillActive) {
            this._restoreDraft()
          } else if (
            !submittedHadStash &&
            !hasNewerDraft &&
            submittedDraftKey &&
            ownsSubmittedDraftNamespace
          ) {
            chatDrafts.clear(submittedDraftKey)
            this._observeDraft(submittedDraftKey, null, submittedDraftNamespace)
          }
          if (ownsSubmittedDraftNamespace && !submittedHadReview) {
            this._clearMigratedSubmittedSources(submittedDraft)
          }
          if (switchedChats && !submittedHadReview) this._restoreDraft()
          // New Comment:
          // 1. If we are in "History Mode" (scrolled up), sending a message should jump us to the latest.
          // 2. Ideally, we just reload the "Latest" page to ensure sync and Live Mode.
          // 3. Or, if we are already at latest, just append.

          // Based on requirements: "jump to first page... message added immediately".
          // Safest approach: Reset list to latest.
          // However, to make it feel instant, we might want to append optimisticly or just let the reset handle it.
          // A full reset causes a loading spinner.
          // Better UX: Append to bottom, then ensure we are in "Live Mode".

          // BUT, if we are in history, appending to bottom might leave a gap if we haven't loaded intermediate messages.
          // So, if !allNewerLoaded, we MUST reset/reload to get the full latest context.

          const listCtrl = this.listController
          if (listCtrl) {
            if (!listCtrl.allNewerLoaded) {
              // In History Mode -> Reset to Latest
              listCtrl.resetToLatest()
              // Note: The new message is in `html`, but resetToLatest fetches from server.
              // There might be a race condition if server value isn't ready, but usually ok.
              // Alternatively, we manually clear list and append `html` + fetch prev?
              // Reset is safest for data consistency.
            } else {
              // Already in Live Mode or at bottom -> Just append and scroll
              this.renderCommentHtml(html, { replaceExisting: false })
              listCtrl.scrollToBottom()
              listCtrl.updateStickiness()
              listCtrl.markCommentsRead()
            }
          }
        }
      })
      .catch((error) => {
        if (submittedDraft.invalidated) return

        // Restore review quotes state on failure so user doesn't lose work
        if (this._reviewStore.hasBackup()) {
          const restoredText = this._reviewStore.restore()
          this.textareaTarget.value = restoredText || ''
          this._renderReviewQuoteChips()
          this._updateSubmitButton()
        }
        this._persistFailedSubmissionDraft(submittedDraft)
        alertDialog(error?.message || 'Failed to submit comment')
      })
      .finally(() => {
        this._pendingDraftSubmissions.delete(submittedDraft)
        inFlightSends.delete(sendKey)
        this._hasRetried = false
        this.setSendingState(false)
        if (
          !submittedDraft.invalidated &&
          submittedDraft.namespace === chatDrafts.namespace()
        ) {
          this._restoreStashedDraft(submittedText)
        } else {
          this._stashedDraft = null
        }
      })
  }

  handlePointerSend(event) {
    if (event.pointerType !== 'mouse') {
      this.handleSend(event)
    }
  }

  handleTouchSend(event) {
    event.preventDefault()
    this.handleSend(event)
  }

  handleCancel(event) {
    event.preventDefault()
    this.resetForm()
    this._restoreDraft()
  }

  handleSearch(event) {
    event.preventDefault()
    const query = this.textareaTarget.value.trim()
    this.presenceController?.clearManualTypingMessage()
    this.listController?.applySearchQuery(query || null)
  }

  handleVoiceToggle(event) {
    event.preventDefault()
    if (this.listening) {
      this.stopSpeechRecognition()
    } else {
      this.startSpeechRecognition()
    }
  }

  setupSpeechRecognition() {
    if (this.recognition) return true

    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SpeechRecognition) {
      alertDialog(this.element.dataset.speechUnavailableText || 'Speech recognition not supported')
      return false
    }

    this.recognition = new SpeechRecognition()
    this.recognition.continuous = true
    this.recognition.interimResults = false
    this.recognition.lang = document.documentElement.lang || 'ko-KR'
    this.recognition.addEventListener('start', this.handleRecognitionStart)
    this.recognition.addEventListener('end', this.handleRecognitionEnd)
    this.recognition.addEventListener('result', this.handleRecognitionResult)
    this.recognition.addEventListener('error', this.handleRecognitionError)
    return true
  }

  startSpeechRecognition() {
    if (!this.setupSpeechRecognition()) return
    if (this.listening) return

    this.listening = true
    this.tryStartRecognition()
  }

  stopSpeechRecognition() {
    this.listening = false
    if (this.recognition) {
      if (this.recognitionActive) {
        this.recognition.stop()
      } else {
        if (this.recognition.abort) this.recognition.abort()
        try {
          this.recognition.stop()
        } catch (error) {
          // ignore invalid state errors from stopping before start
        }
      }
    }
    this.updateVoiceButton(false)
  }

  tryStartRecognition() {
    if (!this.recognition || this.recognitionActive) return
    try {
      this.recognition.start()
    } catch (error) {
      this.handleRecognitionError(error)
    }
  }

  handleRecognitionStart() {
    this.recognitionActive = true
    if (!this.listening) {
      this.recognition.stop()
      return
    }
    this.updateVoiceButton(true)
  }

  handleRecognitionEnd() {
    this.recognitionActive = false
    if (this.listening) {
      this.tryStartRecognition()
    } else {
      this.updateVoiceButton(false)
    }
  }

  handleRecognitionResult(event) {
    const latestResult = event.results[event.resultIndex]
    const transcript = Array.from(latestResult || [])
      .map((result) => result?.transcript)
      .filter(Boolean)
      .join(' ')
      .trim()

    if (!transcript) return

    const currentValue = this.textareaTarget.value
    const needsSpace = currentValue && !currentValue.endsWith(' ')
    this.textareaTarget.value = `${currentValue}${needsSpace ? ' ' : ''}${transcript}`
    this.textareaTarget.dispatchEvent(new Event('input'))
    this.focusTextarea()
  }

  handleRecognitionError() {
    this.listening = false
    this.recognitionActive = false
    this.updateVoiceButton(false)
  }

  updateVoiceButton(active) {
    if (!this.voiceButtonTarget) return
    this.voiceButtonTarget.textContent = active
      ? this.element.dataset.voiceStopText || '중지'
      : this.element.dataset.voiceStartText || '음성'
    this.voiceButtonTarget.classList.toggle('voice-input-active', active)
  }

  teardownSpeechRecognition() {
    if (!this.recognition) return
    this.stopSpeechRecognition()
    this.recognition.removeEventListener('start', this.handleRecognitionStart)
    this.recognition.removeEventListener('end', this.handleRecognitionEnd)
    this.recognition.removeEventListener('result', this.handleRecognitionResult)
    this.recognition.removeEventListener('error', this.handleRecognitionError)
    this.recognition = null
  }

  handleImageButtonClick(event) {
    event.preventDefault()
    this.cachedImageFiles = this.currentImageFiles()
    this.imageInputTarget?.click()
  }

  handleImageChange() {
    if (!this.imageInputTarget) return
    const newFiles = Array.from(this.imageInputTarget.files || [])
    const existingFiles = this.cachedImageFiles ?? []
    this.setImageFiles([...existingFiles, ...newFiles])
    this.cachedImageFiles = null
    this.updateAttachmentList()
  }

  handlePaste(event) {
    const clipboardData = event.clipboardData
    if (!clipboardData) return

    const text = clipboardData.getData('text/plain') || clipboardData.getData('text')
    if (!text) return

    const { changed, result } = wrapHtmlInCodeBlocks(text)
    if (!changed) return

    event.preventDefault()

    const textarea = this.textareaTarget
    const start = textarea.selectionStart
    const end = textarea.selectionEnd
    const before = textarea.value.substring(0, start)
    const after = textarea.value.substring(end)
    // Ensure blank line before code fence if there's preceding text
    const separator = before.length > 0 && !before.endsWith('\n') ? '\n' : ''
    textarea.value = before + separator + result + after
    const cursorPos = start + separator.length + result.length
    textarea.setSelectionRange(cursorPos, cursorPos)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
  }

  handleDragOver(event) {
    const isCreative = this.hasCreativeFromDataTransfer(event.dataTransfer)
    const isImage = this.hasImageFromDataTransfer(event.dataTransfer)
    if (isImage || isCreative) {
      event.preventDefault()
      event.stopPropagation()
      if (isCreative) {
        this.formTarget.classList.add('creative-drop-hover')
      }
    }
  }

  handleDragLeave(event) {
    // Only remove highlight if truly leaving the form
    if (!this.formTarget.contains(event.relatedTarget)) {
      this.formTarget.classList.remove('creative-drop-hover')
    }
  }

  handleDrop(event) {
    this.formTarget.classList.remove('creative-drop-hover')

    // Handle creative drop — stop propagation so contexts_controller doesn't intercept
    if (this.hasCreativeFromDataTransfer(event.dataTransfer)) {
      event.preventDefault()
      event.stopPropagation()
      const creativeData = this.extractCreativeData(event.dataTransfer)
      if (creativeData) {
        this.insertCreativeLink(creativeData)
      }
      return
    }

    // Handle image drop
    const imageFiles = this.extractImageFiles(event.dataTransfer)
    if (!imageFiles.length) return
    event.preventDefault()
    this.setImageFiles([...this.currentImageFiles(), ...imageFiles])
    this.updateAttachmentList()
  }

  hasCreativeFromDataTransfer(dataTransfer) {
    if (!dataTransfer || !dataTransfer.types) return false
    return Array.from(dataTransfer.types).includes('application/x-collavre-creative')
  }

  extractCreativeData(dataTransfer) {
    if (!dataTransfer) return null
    const raw = dataTransfer.getData('application/x-collavre-creative') || dataTransfer.getData('text/plain')
    if (!raw) return null
    try {
      const parsed = JSON.parse(raw)
      if (!parsed || !parsed.creativeId) return null
      const label = this.getCreativeLabelFromDom(parsed.creativeId)
      return { id: parsed.creativeId, label: label || `Creative #${parsed.creativeId}` }
    } catch {
      return null
    }
  }

  getCreativeLabelFromDom(creativeId) {
    const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
    if (!row) return null
    const descriptionHtml = row.descriptionHtml || row.dataset?.descriptionHtml || ''
    if (!descriptionHtml) return null
    const tmp = document.createElement('div')
    tmp.innerHTML = descriptionHtml
    return (tmp.textContent || tmp.innerText || '').trim()
  }

  insertCreativeLink({ id, label }) {
    const link = `[${label}](/creatives/${id})`
    const textarea = this.textareaTarget
    const pos = textarea.selectionStart
    const before = textarea.value.substring(0, pos)
    const after = textarea.value.substring(pos)
    const needsSpace = before.length > 0 && !before.endsWith(' ') && !before.endsWith('\n')
    textarea.value = `${before}${needsSpace ? ' ' : ''}${link}${after ? '' : ' '}${after}`
    const newPos = pos + (needsSpace ? 1 : 0) + link.length + (after ? 0 : 1)
    textarea.setSelectionRange(newPos, newPos)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    textarea.focus()
  }

  extractImageFiles(dataTransfer) {
    if (!dataTransfer) return []
    const files = Array.from(dataTransfer.files || []).filter((file) => file.type?.startsWith('image/'))
    if (files.length > 0) return files
    if (!dataTransfer.items) return []
    return Array.from(dataTransfer.items)
      .map((item) => (item.kind === 'file' ? item.getAsFile() : null))
      .filter((file) => file && file.type?.startsWith('image/'))
  }

  hasImageFromDataTransfer(dataTransfer) {
    return this.extractImageFiles(dataTransfer).length > 0
  }

  setImageFiles(files) {
    if (!this.imageInputTarget) return
    const dataTransfer = new DataTransfer()
    files.forEach((file) => dataTransfer.items.add(file))
    this.imageInputTarget.files = dataTransfer.files
  }

  currentImageFiles() {
    if (!this.imageInputTarget) return []
    return Array.from(this.imageInputTarget.files || [])
  }

  clearImageAttachments() {
    this.cachedImageFiles = null
    this.setImageFiles([])
    this.updateAttachmentList()
  }

  removeImageAttachment(index) {
    const files = this.currentImageFiles().filter((_, fileIndex) => fileIndex !== index)
    this.setImageFiles(files)
    this.updateAttachmentList()
  }

  updateAttachmentList() {
    if (!this.attachmentListTarget) return
    const files = this.currentImageFiles()
    this.attachmentListTarget.innerHTML = ''
    if (!files.length) {
      this.attachmentListTarget.style.display = 'none'
      return
    }

    this.attachmentListTarget.style.display = ''
    files.forEach((file, index) => {
      const item = document.createElement('span')
      item.className = 'comment-attachment-item'
      item.textContent = file.name

      const removeButton = document.createElement('button')
      removeButton.type = 'button'
      removeButton.className = 'comment-attachment-remove'
      removeButton.setAttribute('aria-label', `Remove ${file.name}`)
      removeButton.textContent = '×'
      removeButton.addEventListener('click', () => this.removeImageAttachment(index))

      item.appendChild(removeButton)
      this.attachmentListTarget.appendChild(item)
    })
  }

  quoteComment(commentId, selectedText) {
    if (!commentId || !selectedText) return
    this.quotedCommentIdTarget.value = commentId
    this.quotedTextTarget.value = selectedText
    this.quoteIndicatorTarget.style.display = ''
    this.quoteIndicatorTextTarget.textContent = selectedText.length > 80
      ? selectedText.substring(0, 80) + '…'
      : selectedText
    this.focusTextarea()
  }

  // Append a review quote as a visual chip above the textarea.
  appendReviewQuote(commentId, selectedText) {
    if (!selectedText) return

    const store = this._reviewStore
    if (store.isEmpty) this._flushDraftSave()
    store.saveActiveFeedback(this.textareaTarget.value)

    if (commentId) {
      this.quotedCommentIdTarget.value = commentId
    }

    store.add(commentId, selectedText)
    this._renderReviewQuoteChips()
    this._updateSubmitButton()

    this.textareaTarget.value = ''
    this.textareaTarget.placeholder = this._getI18nText('reviewFeedbackPlaceholder', 'Write feedback for this quote...')
    this.focusTextarea()
  }

  _commitActiveQuote() {
    const store = this._reviewStore
    store.commitActive(this.textareaTarget.value)
    this.textareaTarget.value = ''
    this.textareaTarget.placeholder = this._getI18nText('reviewSummaryPlaceholder', 'Overall comment (optional)...')
    this._renderReviewQuoteChips()
    this._updateSubmitButton()
    this.focusTextarea()
  }

  // Send a single question quote immediately as a standalone comment.
  _sendQuestionQuote(quote) {
    const sendKey = sendKeyFor(this.creativeId)
    if (this.sending || inFlightSends.has(sendKey) || !this.creativeId) return
    inFlightSends.add(sendKey)

    const store = this._reviewStore
    const content = store.buildQuestionContent(quote)

    store.remove(quote.id)
    this.textareaTarget.value = ''

    if (store.isEmpty) {
      this._restoreOrdinaryDraft()
    } else if (!store.hasActive) {
      this.textareaTarget.placeholder = this._getI18nText('reviewSummaryPlaceholder', 'Overall comment (optional)...')
    }
    this._renderReviewQuoteChips()
    this._updateSubmitButton()

    // Send as a question comment with quoted_comment_id preserved + review_type=question
    this.sending = true
    const formData = new FormData()
    formData.append('comment[content]', content)
    formData.append('comment[review_type]', 'question')
    if (quote.commentId) {
      formData.append('comment[quoted_comment_id]', quote.commentId)
    }
    const isPrivate = this.privateCheckboxTarget?.checked ?? false
    if (isPrivate) formData.append('comment[private]', '1')
    const effectiveTopicId = this.currentTopicId || this._mainTopicId
    if (effectiveTopicId) {
      formData.append('comment[topic_id]', effectiveTopicId)
    }

    const url = `/creatives/${this.creativeId}/comments`
    const doFetch = () => fetch(url, {
      method: 'POST',
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
      body: formData,
    })

    doFetch()
      .then((response) => {
        if (response.ok) return response.text()
        if (response.status === 422 && !this._hasRetried) {
          this._hasRetried = true
          return refreshCsrfToken().then(() => doFetch()).then((retryResp) => {
            if (retryResp.ok) return retryResp.text()
            return retryResp.json().then((json) => {
              throw new Error(json.errors?.join(', ') || 'Unable to save comment')
            })
          })
        }
        return response.json().then((json) => {
          throw new Error(json.errors?.join(', ') || 'Unable to save comment')
        })
      })
      .then((html) => {
        this.renderCommentHtml(html)
        const listCtrl = this.application.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="comments--list"]'), 'comments--list'
        )
        if (listCtrl) {
          listCtrl.scrollToBottom()
          listCtrl.updateStickiness()
          listCtrl.markCommentsRead()
        }
      })
      .catch((error) => {
        alertDialog(error?.message || 'Failed to send question')
      })
      .finally(() => {
        inFlightSends.delete(sendKey)
        this._hasRetried = false
        this.sending = false
      })

    this.focusTextarea()
  }

  _renderReviewQuoteChips() {
    const container = this.reviewQuotesContainerTarget
    const store = this._reviewStore
    container.innerHTML = ''

    if (store.isEmpty) {
      container.style.display = 'none'
      return
    }

    container.style.display = ''
    store.quotes.forEach((quote) => {
      const chip = document.createElement('div')
      chip.className = 'review-quote-chip'
      if (quote.id === store.activeId) {
        chip.classList.add('review-quote-chip--active')
      }

      // Type toggle (review / question)
      const typeToggle = document.createElement('button')
      typeToggle.type = 'button'
      typeToggle.className = `review-quote-type-toggle review-quote-type-toggle--${quote.type}`
      typeToggle.textContent = quote.type === 'question'
        ? this._getI18nText('reviewTypeQuestion', '❓')
        : this._getI18nText('reviewTypeReview', '💬')
      typeToggle.title = quote.type === 'question'
        ? this._getI18nText('reviewTypeQuestionLabel', 'Question')
        : this._getI18nText('reviewTypeReviewLabel', 'Review')
      typeToggle.addEventListener('click', (e) => {
        e.stopPropagation()
        store.toggleType(quote.id)
        this._renderReviewQuoteChips()
        this._updateSubmitButton()
      })

      // Quote text
      const textSpan = document.createElement('span')
      textSpan.className = 'review-quote-chip-text'
      const preview = quote.text.length > 60
        ? quote.text.substring(0, 60) + '…'
        : quote.text
      textSpan.textContent = preview
      textSpan.title = quote.text

      // Click chip to edit its feedback
      textSpan.addEventListener('click', () => {
        if (quote.id === store.activeId) {
          const commentEl = document.querySelector(`[data-comment-id="${quote.commentId}"]`)
          if (commentEl) {
            // Programmatic list scroll — drop the prev-message anchor so the next
            // previous-message click resolves from the quoted comment now in view.
            this.listController?.notifyProgrammaticScroll()
            commentEl.scrollIntoView({ behavior: 'smooth', block: 'center' })
            commentEl.classList.add('comment-highlight')
            setTimeout(() => commentEl.classList.remove('comment-highlight'), 2000)
          }
          return
        }
        store.saveActiveFeedback(this.textareaTarget.value)
        store.activate(quote.id)
        this.textareaTarget.value = quote.feedback || ''
        this.textareaTarget.placeholder = this._getI18nText('reviewFeedbackPlaceholder', 'Write feedback for this quote...')
        this._renderReviewQuoteChips()
        this._updateSubmitButton()
        this.focusTextarea()
      })

      // Feedback preview (shown when not active and has feedback)
      const feedbackSpan = document.createElement('span')
      feedbackSpan.className = 'review-quote-chip-feedback'
      if (quote.feedback && quote.id !== store.activeId) {
        const fbPreview = quote.feedback.length > 40
          ? quote.feedback.substring(0, 40) + '…'
          : quote.feedback
        feedbackSpan.textContent = `→ ${fbPreview}`
      }

      // Remove button
      const removeBtn = document.createElement('button')
      removeBtn.type = 'button'
      removeBtn.className = 'review-quote-chip-remove'
      removeBtn.innerHTML = '&times;'
      removeBtn.title = 'Remove'
      removeBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        const wasActive = quote.id === store.activeId
        store.remove(quote.id)
        if (wasActive) this.textareaTarget.value = ''
        if (store.isEmpty) {
          this._restoreOrdinaryDraft()
        } else if (!store.hasActive) {
          this.textareaTarget.placeholder = this._getI18nText('reviewSummaryPlaceholder', 'Overall comment (optional)...')
        }
        this._renderReviewQuoteChips()
        this._updateSubmitButton()
      })

      chip.appendChild(typeToggle)
      chip.appendChild(textSpan)
      if (quote.feedback && quote.id !== store.activeId) {
        chip.appendChild(feedbackSpan)
      }
      chip.appendChild(removeBtn)
      container.appendChild(chip)
    })
  }

  _updateSubmitButton() {
    const state = this._reviewStore.buttonState
    if (state === 'normal') {
      this.submitTarget.innerHTML = this.defaultSubmitHTML
      this.submitTarget.classList.remove('review-submit-btn')
      return
    }

    this.submitTarget.classList.add('review-submit-btn')
    const labels = {
      'add': this._getI18nText('reviewAddQuote', '+ Add'),
      'send-review': this._getI18nText('reviewSend', 'Send review'),
      'send-question': this._getI18nText('reviewSendQuestion', 'Send question'),
    }
    this.submitTarget.textContent = labels[state]
  }

  _restoreOrdinaryDraft() {
    this.textareaTarget.value = ''
    this.textareaTarget.placeholder = this._defaultPlaceholder()
    this._restoreDraft()
  }

  _getI18nText(key, fallback) {
    return this.element.dataset[key] || fallback
  }

  _defaultPlaceholder() {
    return this._getI18nText('chatInputHint', 'Type a message, or use / for commands')
  }

  // --- Inbox inline reply mode ---

  get _isInboxSystemTopic() {
    return this._isInbox && this._systemTopicId &&
      String(this.currentTopicId) === String(this._systemTopicId)
  }

  _updateInboxReplyMode() {
    if (!this._isInboxSystemTopic) {
      this._inboxReplyMode = false
      // Reset submit button if not in review mode
      if (!this._reviewStore || this._reviewStore.isEmpty) {
        this.submitTarget.innerHTML = this.defaultSubmitHTML
        this.submitTarget.classList.remove('inbox-reply-btn')
      }
      if (this._inboxReplyIndicator) {
        this.quoteIndicatorTarget.style.display = 'none'
        this.quoteIndicatorTextTarget.textContent = ''
        this._inboxReplyIndicator = false
      }
      if (this.hasQuoteCancelButtonTarget) {
        this.quoteCancelButtonTarget.style.display = ''
      }
      return
    }

    this._inboxReplyMode = true

    // Hide cancel button — inbox reply mode has no cancel action
    if (this.hasQuoteCancelButtonTarget) {
      this.quoteCancelButtonTarget.style.display = 'none'
    }

    // Find the latest alarm (system message) in the comment list
    const latestAlarm = this._findLatestAlarm()
    if (latestAlarm) {
      const alarmText = latestAlarm.textContent?.trim() || ''
      const truncated = alarmText.length > 100 ? alarmText.substring(0, 100) + '…' : alarmText
      this.quoteIndicatorTarget.style.display = ''
      this.quoteIndicatorTextTarget.textContent = truncated
      this._inboxReplyIndicator = true
    }

    // Change submit button to reply text
    this.submitTarget.textContent = this._getI18nText('inboxReplyButton', 'Reply')
    this.submitTarget.classList.add('inbox-reply-btn')
  }

  _findLatestAlarm() {
    const list = document.getElementById('comments-list')
    if (!list) return null

    // System messages have data-user-id="" (no user)
    const allComments = list.querySelectorAll('.comment-item')
    let latest = null
    for (const el of allComments) {
      if (!el.dataset.userId) {
        latest = el
      }
    }
    // Get the content element from the latest system message
    if (latest) {
      return latest.querySelector('.comment-content')
    }
    return null
  }

  cancelQuote() {
    this.quotedCommentIdTarget.value = ''
    this.quotedTextTarget.value = ''
    this.quoteIndicatorTarget.style.display = 'none'
    this.quoteIndicatorTextTarget.textContent = ''
    this._reviewStore.clear()
    this._renderReviewQuoteChips()
    this._updateSubmitButton()
    this.textareaTarget.placeholder = this._defaultPlaceholder()
    // Re-apply inbox reply mode indicator if we're in inbox System topic
    if (this._isInboxSystemTopic) {
      requestAnimationFrame(() => this._updateInboxReplyMode())
    }
  }

  renderCommentHtml(html, { replaceExisting = false } = {}) {
    const listElement = document.getElementById('comments-list')
    if (!listElement || !html) return

    const parser = new DOMParser()
    const doc = parser.parseFromString(html, 'text/html')
    const commentElement = doc.querySelector('.comment-item')
    if (!commentElement) return

    // A search-filtered list is the result set of a server-side query, and a
    // freshly posted comment carries no verdict on whether it matches. Splicing
    // it in drops an unrelated message among the results and — when there were
    // none — takes the "no results" notice with it, since removePlaceholder
    // below clears whatever empty state is on screen. Leave search and reload
    // the live list instead, the same exit the history-mode branch takes.
    // Edits are exempt: that comment is already in the result set, matching the
    // stream path, which blocks `append` but never `replace`/`remove`.
    const listCtrl = this.listController
    if (!replaceExisting && listCtrl?.manualSearchQuery) {
      listCtrl.resetToLatest()
      return
    }

    this.removePlaceholder()

    const existing = listElement.querySelector(`#${commentElement.id}`)
    if (existing) {
      existing.replaceWith(commentElement)
    } else {
      listElement.appendChild(commentElement)
    }

    renderMarkdownInContainer(commentElement)
    if (replaceExisting) {
      this.listController?.markCommentsRead()
    }
  }

  removePlaceholder() {
    const listElement = document.getElementById('comments-list')
    // Every empty-list state carries .comments-placeholder: the discovery
    // cards (#no-comments) and the no-search-results notice. Either can be on
    // screen when the user posts.
    listElement?.querySelectorAll('.comments-placeholder').forEach((el) => el.remove())
  }
}
