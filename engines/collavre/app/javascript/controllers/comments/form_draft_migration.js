import chatDrafts from '../../lib/chat_drafts'
import FormDraftPersistence from './form_draft_persistence'

export default class FormDraftMigration extends FormDraftPersistence {
	handleTopicChange() {
		const context = this._nextDraftContext()
		const resolvingIncomingDraftKey = this._isResolvingDraftKey(context.nextCreativeId)
		let keepAwaitingEffectiveDraftKey = false

		if (this._draftContextChanged(context)) {
			keepAwaitingEffectiveDraftKey = this._changeDraftContext(context, resolvingIncomingDraftKey)
		}
		if (resolvingIncomingDraftKey && !keepAwaitingEffectiveDraftKey) {
			this._awaitingEffectiveDraftKeyFor = null
		}
	}

	_nextDraftContext() {
		if (this._draftPersistenceDisabled()) return { nextDraftKey: null, nextCreativeId: null }

		return {
			nextDraftKey: this.element.dataset.effectiveCreativeId || this.element.dataset.creativeId || null,
			nextCreativeId: this.element.dataset.creativeId || null,
		}
	}

	_isResolvingDraftKey(nextCreativeId) {
		return Boolean(
			this._awaitingEffectiveDraftKeyFor &&
			String(this._awaitingEffectiveDraftKeyFor) === String(nextCreativeId || ''),
		)
	}

	_draftContextChanged({ nextDraftKey, nextCreativeId }) {
		return String(this._activeDraftKey || '') !== String(nextDraftKey || '') ||
			String(this._activeDraftCreativeId || '') !== String(nextCreativeId || '')
	}

	_changeDraftContext({ nextDraftKey, nextCreativeId }, resolvingIncomingDraftKey) {
		const previousDraftKey = this._activeDraftKey
		if (!resolvingIncomingDraftKey || this._draftSaveTimer) this._flushDraftSave()
		this._activeDraftKey = nextDraftKey ? String(nextDraftKey) : null
		this._activeDraftCreativeId = nextCreativeId ? String(nextCreativeId) : null
		if (!resolvingIncomingDraftKey || !previousDraftKey || !this._activeDraftKey) return false

		return this._migrateDraftKey(previousDraftKey)
	}

	_migrateDraftKey(sourceKey) {
		const targetKey = this._activeDraftKey
		const sourceDraft = chatDrafts.snapshot(sourceKey)
		const moveCompleted = chatDrafts.move(sourceKey, targetKey)
		const targetDraft = chatDrafts.snapshot(targetKey)
		const movedBackups = moveCompleted
			? chatDrafts.moveSubmissionBackups(sourceKey, targetKey)
			: new Map()
		const migration = { sourceKey, targetKey, sourceDraft, targetDraft, movedBackups }

		if (moveCompleted && (targetDraft.revision || !sourceDraft.revision)) {
			this._rebindPendingDraftSubmissions(migration)
			return false
		}
		if (moveCompleted) return false

		this._trackPartialDraftMigration(sourceKey, targetKey, sourceDraft, targetDraft)
		if (!chatDrafts.isNewer(sourceKey, targetKey)) return false

		this._activeDraftKey = String(sourceKey)
		return true
	}

	_rebindPendingDraftSubmissions(migration) {
		const namespace = chatDrafts.namespace()
		const context = {
			...migration,
			namespace,
			targetRevisionKey: `${namespace}:${migration.targetKey}`,
		}
		this._pendingDraftSubmissions?.forEach((submission) => {
			this._rebindPendingDraftSubmission(submission, context)
		})
	}

	_rebindPendingDraftSubmission(submission, context) {
		const { namespace, sourceKey, targetKey, sourceDraft, targetDraft, movedBackups } = context
		if (submission.namespace !== namespace || String(submission.key) !== String(sourceKey)) return

		const submittedDraftWasMoved = this._submittedDraftWasMoved(submission, context)
		this._recordMigratedSubmissionSource(submission, context)
		submission.key = String(targetKey)
		submission.revisionKey = context.targetRevisionKey
		submission.keyRevision = this._draftRevisions?.get(context.targetRevisionKey) || 0
		submission.storedRevision = targetDraft.revision
		submission.storedUpdatedAt = targetDraft.updatedAt
		submission.storedChangedOutsideController ||= !submittedDraftWasMoved
		if (submission.backupKey && movedBackups.has(submission.backupKey)) {
			submission.backupKey = movedBackups.get(submission.backupKey)
		}
	}

	_submittedDraftWasMoved(submission, { sourceDraft, targetDraft }) {
		const targetMatchesStoredBaseline = submission.storedRevision &&
			targetDraft.revision === submission.storedRevision
		const sourceMatchesSubmission = sourceDraft.revision &&
			targetDraft.revision === sourceDraft.revision &&
			targetDraft.text === submission.text
		const submittedDraftWasUnstored = !submission.storedRevision &&
			!sourceDraft.revision && !targetDraft.revision
		return targetMatchesStoredBaseline ||
			sourceMatchesSubmission || submittedDraftWasUnstored
	}

	_recordMigratedSubmissionSource(submission, { sourceKey, sourceDraft }) {
		if (sourceDraft.revision && sourceDraft.text === submission.text) {
			submission.migratedSources.push({
				key: String(sourceKey),
				revision: sourceDraft.revision,
			})
		}
	}

	_trackPartialDraftMigration(sourceKey, targetKey, sourceDraft, targetDraft) {
		if (!sourceDraft.revision || targetDraft.revision !== sourceDraft.revision) return

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
}
