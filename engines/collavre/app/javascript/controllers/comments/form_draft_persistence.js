import chatDrafts from '../../lib/chat_drafts'

export default class FormDraftPersistence {
	_saveDraftNow() {
		if (!this._canPersistCurrentDraft() || this._currentTextIsPendingSubmission()) return

		const snapshot = this._draftSaveSnapshot()
		if (!snapshot.draftChangedLocally && snapshot.storedDraftChangedOutsideController) return

		this._persistDraftSnapshot(snapshot)
		if (snapshot.blank && snapshot.draftChangedLocally) {
			chatDrafts.clearSubmissionBackups(snapshot.draftKey)
		}
		this._observeDraft(snapshot.draftKey)
	}

	_canPersistCurrentDraft() {
		return Boolean(
			this._activeDraftKey &&
			!this._draftPersistenceDisabled() &&
			!this._draftSaveSuspendedForPermission &&
			!this.editingId &&
			!this._shouldSuppressDraftSaveForStash() &&
			this._reviewStore.isEmpty,
		)
	}

	_draftSaveSnapshot() {
		const draftKey = this._activeDraftKey
		const text = this.textareaTarget.value
		const blank = !text.trim()
		const storedDraft = chatDrafts.snapshot(draftKey)
		const hasStoredEntry = chatDrafts.updatedAt(draftKey) !== null
		const observationKey = `${chatDrafts.namespace()}:${draftKey}`
		const observation = this._draftObservation(observationKey, text)

		return {
			draftKey,
			text,
			blank,
			storedText: storedDraft.text,
			hasStoredEntry,
			preserveBlank: blank && Boolean(this._awaitingEffectiveDraftKeyFor) &&
				observation.inputChangedLocally,
			draftChangedLocally: observation.inputChangedLocally || observation.displayedDraftChanged,
			storedDraftChangedOutsideController: observation.hasObservedDraft && (
				observation.observedText !== storedDraft.text ||
				observation.observedStoredRevision !== storedDraft.revision
			),
		}
	}

	_draftObservation(observationKey, text) {
		const hasObservedDraft = this._observedDrafts?.has(observationKey)
		const observedText = this._observedDrafts?.get(observationKey)
		const hasObservedDisplayedDraft = this._observedDisplayedDrafts?.has(observationKey)
		const observedDisplayedText = hasObservedDisplayedDraft
			? this._observedDisplayedDrafts.get(observationKey)
			: observedText
		const { observedRevision, observedStoredRevision, currentRevision } =
			this._draftObservationRevisions(observationKey)
		const inputChangedLocally = currentRevision !== observedRevision
		const displayedDraftChanged = (hasObservedDisplayedDraft || hasObservedDraft) &&
			(observedDisplayedText || '') !== text

		return {
			hasObservedDraft,
			observedText,
			observedStoredRevision,
			inputChangedLocally,
			displayedDraftChanged,
		}
	}

	_draftObservationRevisions(observationKey) {
		return {
			observedRevision: this._observedDraftRevisions?.get(observationKey) || 0,
			observedStoredRevision: this._observedStoredDraftRevisions?.get(observationKey) || null,
			currentRevision: this._draftRevisions?.get(observationKey) || 0,
		}
	}

	_persistDraftSnapshot({ draftKey, text, blank, storedText, hasStoredEntry, preserveBlank }) {
		if (preserveBlank) {
			if (storedText !== null || !hasStoredEntry) {
				chatDrafts.set(draftKey, '', { preserveBlank: true })
			}
		} else if (blank) {
			if (hasStoredEntry) chatDrafts.clear(draftKey)
		} else if (storedText !== text) {
			chatDrafts.set(draftKey, text)
		}
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
		if (!this._activeDraftKey || this._draftPersistenceDisabled() || this.editingId) return
		if (this.textareaTarget.value.trim()) return

		const draft = chatDrafts.snapshot(this._activeDraftKey)
		const backup = chatDrafts.latestSubmissionBackup(this._activeDraftKey)
		const restoreBackup = Boolean(
			backup?.text && (draft.updatedAt === null || backup.updatedAt > draft.updatedAt),
		)
		if (backup && !restoreBackup) chatDrafts.removeSubmissionBackup(backup.key)
		const restoredText = restoreBackup ? backup.text : draft.text
		this._observeDraft(this._activeDraftKey, draft.text, {
			storedRevision: draft.revision,
			displayedText: restoredText,
		})
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
		chatDrafts.clearAll({ broadcast: false })
	}

	_observeDraft(draftKey, text, options = {}) {
		if (!draftKey) return
		const {
			namespace = chatDrafts.namespace(),
			storedRevision,
			displayedText,
		} = options
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

	_clearMigratedSubmittedSources(submission) {
		submission.migratedSources.forEach(({ key, revision }) => {
			if (chatDrafts.revision(key) !== revision) return

			chatDrafts.clear(key)
			this._observeDraft(key, null, { namespace: submission.namespace })
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
		const currentKeyRevision = this._draftRevisions?.get(submission.revisionKey) || 0
		const submittedChatAdvanced = submission.storedChangedOutsideController ||
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
