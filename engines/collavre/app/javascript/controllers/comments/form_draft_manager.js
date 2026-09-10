import chatDrafts from '../../lib/chat_drafts'

// Owns the stateful draft lifecycle while the Stimulus controller coordinates UI concerns.
export default class FormDraftManager {
  constructor(form) {
    this.form = form
  }

  get element() { return this.form.element }
  get textareaTarget() { return this.form.textareaTarget }
  get editingId() { return this.form.editingId }
  set editingId(value) { this.form.editingId = value }
  get creativeId() { return this.form.creativeId }
  set creativeId(value) { this.form.creativeId = value }
  get _reviewStore() { return this.form._reviewStore }

  _autoResize() {
    this.form._autoResize()
  }

  _updateSubmitButton() {
    this.form._updateSubmitButton()
  }

  resetForm() {
    this.form.resetForm()
  }

  connect() {
    // Draft persistence: debounce-save unsent input per chat.
    // _activeDraftKey always identifies the chat whose text is in the textarea.
    this._activeDraftKey ??= null
    this._activeDraftCreativeId ??= null
    this._awaitingEffectiveDraftKeyFor ??= null
    this._draftSaveTimer = null
    this._draftSaveSuspendedForPermission ??= false
    // A cross-tab logout permanently retires the old user's namespace for this
    // controller lifetime, including Stimulus reconnects in the stale tab.
    this._disabledDraftNamespaces ||= new Set()
    this._draftBackupCleanupPendingNamespaces ||= new Set()
    this._observedDraftClearNonces ||= new Map()
    // A pending send survives a Stimulus reconnect on this controller instance,
    // so its completion must keep comparing against the same draft history.
    this._draftRevisions ||= new Map()
    this._observedDrafts ||= new Map()
    this._observedDisplayedDrafts ||= new Map()
    this._observedDraftRevisions ||= new Map()
    this._observedStoredDraftRevisions ||= new Map()
    // A linked chat can replace its temporary raw key while its request is in
    // flight. Keep mutable submission state across that migration/reconnect.
    this._pendingDraftSubmissions ||= new Set()
    const draftNamespace = chatDrafts.namespace()
    const draftClearNonce = chatDrafts.clearNonce(draftNamespace)
    const draftClearNoncePending = chatDrafts.clearNoncePending(draftNamespace)
    const observedDraftClearNonce = this._observedDraftClearNonces.has(draftNamespace)
    let canObserveDraftClearNonce = true
    if (draftClearNonce && !observedDraftClearNonce) {
      canObserveDraftClearNonce = chatDrafts.clearSubmissionBackupsForClear(
	draftNamespace,
	draftClearNonce,
      )
      if (canObserveDraftClearNonce && !draftClearNoncePending) {
	this._draftBackupCleanupPendingNamespaces.delete(draftNamespace)
      } else {
	this._draftBackupCleanupPendingNamespaces.add(draftNamespace)
      }
    }
    if (
      draftClearNonce &&
      observedDraftClearNonce &&
      this._observedDraftClearNonces.get(draftNamespace) !== draftClearNonce
    ) {
      this._disableDraftNamespace(draftNamespace)
    }
    if (
      draftClearNonce !== undefined &&
      canObserveDraftClearNonce &&
      !draftClearNoncePending
    ) {
      this._observedDraftClearNonces.set(draftNamespace, draftClearNonce)
    }
    this._handlePageHide = () => {
      if (!this.element.isConnected) return

      this._flushDraftSave()
    }
    this._handleDraftStorage = (event) => {
      if (!this.element.isConnected || !chatDrafts.wasCleared(event)) return

      const clearedNamespace = chatDrafts.namespace()
      this._disableDraftNamespace(clearedNamespace)
    }
    this._handleCompositionEnd = () => {
      this._imeCommitPending = true
    }
    // Chrome fires the commit `input` after `compositionend`, but Firefox has
    // shipped the reverse order, where the commit input consumes the latch
    // before it is even set. Nothing would clear the leftover latch, so the
    // next ordinary edit would be misread as a commit. The commit input always
    // arrives before the user can act again, so any fresh gesture expires it.
    this._expireImeCommitLatch = (event) => {
      if (event?.isComposing || event?.keyCode === 229) return

      this._imeCommitPending = false
    }
    this._handleDraftInput = (event) => {
      // Consume the composition flag before any early return, so it can never
      // outlive the `input` event that the commit itself fired. Firefox has
      // shipped both orderings, so accept isComposing on the input event too.
      const isImeCommit = Boolean(event?.isComposing) || this._imeCommitPending === true
      this._imeCommitPending = false
      if (
	this.editingId ||
	this._draftPersistenceDisabled() ||
	this._draftSaveSuspendedForPermission ||
	this._shouldSuppressDraftSaveForStash() ||
	!this._reviewStore.isEmpty ||
	!this._activeDraftKey
      ) return
      // An IME commit fires `input` after the keydown that started a send, so
      // the textarea still holds exactly what went to the server. Counting it
      // as a revision would defeat _currentPendingSubmission and make the sent
      // message look like a draft typed mid-flight, restoring it on success.
      // Text equality alone is not enough to suppress: re-entering the same
      // string mid-flight (select-all + paste to send it twice) is a real edit.
      if (isImeCommit && this._currentTextIsPendingSubmission()) return
      const revisionKey = `${chatDrafts.namespace()}:${this._activeDraftKey}`
      this._draftRevisions.set(revisionKey, (this._draftRevisions.get(revisionKey) || 0) + 1)
      clearTimeout(this._draftSaveTimer)
      this._draftSaveTimer = setTimeout(() => this._saveDraftNow(), 500)
    }
    this.textareaTarget.addEventListener('compositionend', this._handleCompositionEnd)
    this.textareaTarget.addEventListener('keydown', this._expireImeCommitLatch)
    this.textareaTarget.addEventListener('paste', this._expireImeCommitLatch)
    this.textareaTarget.addEventListener('drop', this._expireImeCommitLatch)
    this.textareaTarget.addEventListener('input', this._handleDraftInput)
    window.addEventListener('pagehide', this._handlePageHide)
    window.addEventListener('storage', this._handleDraftStorage)
  }

  disconnect() {
    this._flushDraftSave()
    this.textareaTarget.removeEventListener('compositionend', this._handleCompositionEnd)
    this.textareaTarget.removeEventListener('keydown', this._expireImeCommitLatch)
    this.textareaTarget.removeEventListener('paste', this._expireImeCommitLatch)
    this.textareaTarget.removeEventListener('drop', this._expireImeCommitLatch)
    this.textareaTarget.removeEventListener('input', this._handleDraftInput)
    window.removeEventListener('pagehide', this._handlePageHide)
    window.removeEventListener('storage', this._handleDraftStorage)
  }

  handleTopicChange() {
    // This event fires before onPopupOpened during a chat switch, while the
    // textarea still contains the outgoing chat's text. Flush before re-keying.
    const draftPersistenceDisabled = this._draftPersistenceDisabled()
    const nextDraftKey = draftPersistenceDisabled
      ? null
      : this.element.dataset.effectiveCreativeId || this.element.dataset.creativeId || null
    const nextCreativeId = draftPersistenceDisabled
      ? null
      : this.element.dataset.creativeId || null
    const draftKeyChanged = String(this._activeDraftKey || '') !== String(nextDraftKey || '')
    const creativeChanged =
      String(this._activeDraftCreativeId || '') !== String(nextCreativeId || '')
    const resolvingIncomingDraftKey =
      this._awaitingEffectiveDraftKeyFor &&
      String(this._awaitingEffectiveDraftKeyFor) === String(nextCreativeId || '')
    let keepAwaitingEffectiveDraftKey = false
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
	const moveCompleted = chatDrafts.move(previousDraftKey, this._activeDraftKey)
	const targetDraft = chatDrafts.snapshot(this._activeDraftKey)
	const movedBackups = moveCompleted
	  ? chatDrafts.moveSubmissionBackups(previousDraftKey, this._activeDraftKey)
	  : new Map()
	if (moveCompleted && (targetDraft.revision || !sourceDraft.revision)) {
	  this._rebindPendingDraftSubmissions(
	    previousDraftKey,
	    this._activeDraftKey,
	    sourceDraft,
	    targetDraft,
	    movedBackups,
	  )
	} else if (!moveCompleted) {
	  this._trackPartialDraftMigration(
	    previousDraftKey,
	    this._activeDraftKey,
	    sourceDraft,
	    targetDraft,
	  )
	  if (chatDrafts.isNewer(previousDraftKey, this._activeDraftKey)) {
	    this._activeDraftKey = String(previousDraftKey)
	    keepAwaitingEffectiveDraftKey = true
	  }
	}
      }
    }
    if (resolvingIncomingDraftKey && !keepAwaitingEffectiveDraftKey) {
      this._awaitingEffectiveDraftKeyFor = null
    }
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
    if (this._draftPersistenceDisabled()) {
      this._activeDraftKey = null
      this._activeDraftCreativeId = null
      this._awaitingEffectiveDraftKeyFor = null
      this.creativeId = creativeId
      this.resetForm()
      return
    }
    this._activeDraftKey = nextCreativeId
    this._activeDraftCreativeId = nextCreativeId
    this._awaitingEffectiveDraftKeyFor = nextCreativeId
    this.creativeId = creativeId
    this.resetForm()
    this._restoreDraft()
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

  _saveDraftNow() {
    if (
      !this._activeDraftKey ||
      this._draftPersistenceDisabled() ||
      this._draftSaveSuspendedForPermission ||
      this.editingId ||
      this._shouldSuppressDraftSaveForStash() ||
      !this._reviewStore.isEmpty
    ) return
    if (this._currentTextIsPendingSubmission()) return
    const draftKey = this._activeDraftKey
    const text = this.textareaTarget.value
    const blank = !text.trim()
    const storedDraft = chatDrafts.snapshot(draftKey)
    const storedText = storedDraft.text
    const hasStoredEntry = chatDrafts.updatedAt(draftKey) !== null
    const observationKey = `${chatDrafts.namespace()}:${draftKey}`
    const hasObservedDraft = this._observedDrafts?.has(observationKey)
    const observedText = this._observedDrafts?.get(observationKey)
    const hasObservedDisplayedDraft =
      this._observedDisplayedDrafts?.has(observationKey)
    const observedDisplayedText = hasObservedDisplayedDraft
      ? this._observedDisplayedDrafts.get(observationKey)
      : observedText
    const observedRevision = this._observedDraftRevisions?.get(observationKey) || 0
    const observedStoredRevision =
      this._observedStoredDraftRevisions?.get(observationKey) || null
    const currentRevision = this._draftRevisions?.get(observationKey) || 0
    const inputChangedLocally = currentRevision !== observedRevision
    const preserveBlank =
      blank && Boolean(this._awaitingEffectiveDraftKeyFor) && inputChangedLocally
    const displayedDraftChanged =
      (hasObservedDisplayedDraft || hasObservedDraft) &&
      (observedDisplayedText || '') !== text
    const draftChangedLocally =
      inputChangedLocally || displayedDraftChanged
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
    if (
      !this._activeDraftKey ||
      this._draftPersistenceDisabled() ||
      this.editingId
    ) return
    if (this.textareaTarget.value.trim()) return

    const draft = chatDrafts.snapshot(this._activeDraftKey)
    const backup = chatDrafts.latestSubmissionBackup(this._activeDraftKey)
    const restoreBackup = Boolean(
      backup?.text &&
      (draft.updatedAt === null || backup.updatedAt > draft.updatedAt),
    )
    if (backup && !restoreBackup) chatDrafts.removeSubmissionBackup(backup.key)
    const restoredText = restoreBackup ? backup.text : draft.text
    this._observeDraft(
      this._activeDraftKey,
      draft.text,
      chatDrafts.namespace(),
      draft.revision,
      restoredText,
    )
    if (restoredText) {
      this.textareaTarget.value = restoredText
      requestAnimationFrame(() => this._autoResize())
    } else if (draft.updatedAt === null) {
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

  _draftPersistenceDisabled(namespace = chatDrafts.namespace()) {
    return this._disabledDraftNamespaces?.has(namespace) ||
      this._draftBackupCleanupPendingNamespaces?.has(namespace) ||
      false
  }

  _disableDraftNamespace(namespace) {
    this._disabledDraftNamespaces.add(namespace)
    this.discardDraft()
    // A timer in this tab may have raced with the logout tab's first clear.
    chatDrafts.clearAll({ broadcast: false })
  }

  _observeDraft(
    draftKey,
    text,
    namespace = chatDrafts.namespace(),
    storedRevision,
    displayedText,
  ) {
    if (!draftKey) return
    const storedDraft = storedRevision === undefined
      ? chatDrafts.snapshot(draftKey)
      : { text, revision: storedRevision }
    const observationKey = `${namespace}:${draftKey}`
    this._observedDrafts?.set(observationKey, storedDraft.text)
    this._observedDisplayedDrafts?.set(
      observationKey,
      displayedText === undefined ? storedDraft.text : displayedText,
    )
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

      const targetMatchesStoredBaseline = submission.storedRevision && targetDraft.revision === submission.storedRevision
      const sourceMatchesSubmission =
	sourceDraft.revision &&
	targetDraft.revision === sourceDraft.revision &&
	targetDraft.text === submission.text
      const submittedDraftWasUnstored =
	!submission.storedRevision &&
	!sourceDraft.revision &&
	!targetDraft.revision
      const submittedDraftWasMoved = targetMatchesStoredBaseline || sourceMatchesSubmission || submittedDraftWasUnstored
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
      submission.storedUpdatedAt = targetDraft.updatedAt
      submission.storedChangedOutsideController ||=
	!submittedDraftWasMoved
      if (submission.backupKey && movedBackups.has(submission.backupKey)) {
	submission.backupKey = movedBackups.get(submission.backupKey)
      }
    })
  }

  _trackPartialDraftMigration(sourceKey, targetKey, sourceDraft, targetDraft) {
    if (
      !sourceDraft.revision ||
      targetDraft.revision !== sourceDraft.revision
    ) return

    const namespace = chatDrafts.namespace()
    this._pendingDraftSubmissions?.forEach((submission) => {
      if (
	submission.namespace !== namespace ||
	String(submission.key) !== String(sourceKey) ||
	submission.hadStash ||
	submission.hadReview ||
	submission.editing ||
	submission.storedRevision !== sourceDraft.revision
      ) return

      submission.migratedSources.push({
	key: String(targetKey),
	revision: targetDraft.revision,
      })
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

    const currentDraft = chatDrafts.snapshot(submission.key)
    const currentKeyRevision =
      this._draftRevisions?.get(submission.revisionKey) || 0
    const submittedChatAdvanced =
      submission.storedChangedOutsideController ||
      currentKeyRevision !== submission.keyRevision ||
      currentDraft.revision !== submission.storedRevision ||
      currentDraft.updatedAt !== submission.storedUpdatedAt
    if (submittedChatAdvanced) return

    submission.backupKey ||= chatDrafts.saveSubmissionBackup(
      submission.key,
      submission.text,
      { updatedAt: submission.backupUpdatedAt },
    )
  }
}
