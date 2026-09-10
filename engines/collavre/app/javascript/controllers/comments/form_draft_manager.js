import chatDrafts from '../../lib/chat_drafts'
import FormDraftMigration from './form_draft_migration'

// Owns the stateful draft lifecycle while the Stimulus controller coordinates UI concerns.
export default class FormDraftManager extends FormDraftMigration {
  constructor(form) {
    super()
    this.form = form
  }

  get element() { return this.form.element }
  get textareaTarget() { return this.form.textareaTarget }
  get editingId() { return this.form.editingId }
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
    this._initializeDraftState()
    this._observeDraftClearState()
    this._defineLifecycleHandlers()
    this._defineImeHandlers()
    this._defineDraftInputHandler()
    this._addDraftEventListeners()
  }

  _initializeDraftState() {
    this._initializeDraftIdentityState()
    this._initializeDraftObservationState()
  }

  _initializeDraftIdentityState() {
    this._activeDraftKey ??= null
    this._activeDraftCreativeId ??= null
    this._awaitingEffectiveDraftKeyFor ??= null
    this._draftSaveTimer = null
    this._draftSaveSuspendedForPermission ??= false
    this._disabledDraftNamespaces ||= new Set()
    this._draftBackupCleanupPendingNamespaces ||= new Set()
    this._observedDraftClearNonces ||= new Map()
  }

  _initializeDraftObservationState() {
    this._draftRevisions ||= new Map()
    this._observedDrafts ||= new Map()
    this._observedDisplayedDrafts ||= new Map()
    this._observedDraftRevisions ||= new Map()
    this._observedStoredDraftRevisions ||= new Map()
    this._pendingDraftSubmissions ||= new Set()
  }

  _observeDraftClearState() {
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
  }

  _defineLifecycleHandlers() {
    this._handlePageHide = () => {
      if (!this.element.isConnected) return

      this._flushDraftSave()
    }
    this._handleDraftStorage = (event) => {
      if (!this.element.isConnected || !chatDrafts.wasCleared(event)) return

      const clearedNamespace = chatDrafts.namespace()
      this._disableDraftNamespace(clearedNamespace)
    }
  }

  _defineImeHandlers() {
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
  }

  _defineDraftInputHandler() {
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
  }

  _addDraftEventListeners() {
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

}
