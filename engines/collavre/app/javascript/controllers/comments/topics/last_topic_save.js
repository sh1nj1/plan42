export default class LastTopicSave {
	constructor(topics) {
		this.topics = topics
	}

	enqueue(context) {
		return this.topics.saveOrderState.enqueue(() => this._save(context))
	}

	async _save(context) {
		const claimed = this._claimEcho(context)
		const saveResult = await this.topics.saveLastTopicWithTimeout(
			context.creativeId,
			context.id || null,
			context.clientId,
		)
		const outcome = this._outcome(context, saveResult)
		if (claimed && outcome.saved) this._handleSaved(context, outcome)
		this._finish(context, outcome, claimed)
	}

	_claimEcho({ id, effectiveCreativeId, clientId, generation }) {
		const topics = this.topics
		const claimed = generation === topics.subscriptionGenerationFor(effectiveCreativeId)
		if (!claimed) return false

		const previousTopicId = topics.lastKnownRemoteTopicIdFor(effectiveCreativeId)
		topics.selfEchoState.claim(clientId, {
			creativeId: effectiveCreativeId,
			topicId: id,
			previousTopicId: previousTopicId === undefined ? topics.serverLastTopicId : previousTopicId,
			possiblyMissed: topics._popupClosed && !topics.topicsSubscription,
		})
		return true
	}

	_outcome(context, saveResult) {
		const savedRevision = this.topics.normalizeLastTopicRevision(saveResult?.lastTopicRevision)
		return {
			saveResult,
			savedRevision,
			saved: saveResult === true || saveResult?.success === true,
			savedRevisionIsCurrent: this.topics.observeLastTopicRevision(
				context.effectiveCreativeId,
				savedRevision,
			),
			topicId: context.id ? String(context.id) : "",
			rejected: saveResult === false || saveResult?.success === false,
			stale: saveResult?.staleLastTopicSave === true,
		}
	}

	_handleSaved(context, outcome) {
		const topics = this.topics
		const hasPendingSelfEcho = this._recordAcknowledgement(context, outcome)
		const echoState = this._echoState(context)
		if (echoState.cannotArrive) {
			topics.setLastKnownRemoteTopicId(context.effectiveCreativeId, outcome.topicId)
			if (echoState.missedDuringDisconnect) {
				topics.retirePendingSelfEcho(context.clientId)
			} else {
				topics.releasePendingSelfEcho(context.clientId)
			}
			return
		}

		if (hasPendingSelfEcho && outcome.savedRevisionIsCurrent) {
			topics.setLastKnownRemoteTopicId(context.effectiveCreativeId, outcome.topicId)
		}
		topics.acknowledgePendingSelfEcho(context.clientId)
	}

	_recordAcknowledgement({ clientId }, { savedRevision }) {
		const topics = this.topics
		const hasPendingSelfEcho = topics.pendingSelfEchoes.includes(clientId)
		if (!hasPendingSelfEcho) return false

		topics.saveAcknowledgementVersion += 1
		topics.pendingSelfEchoAcknowledgementVersions.set(
			clientId,
			topics.saveAcknowledgementVersion,
		)
		if (savedRevision) topics.pendingSelfEchoRemoteRevisions.set(clientId, savedRevision)
		return true
	}

	_echoState({ effectiveCreativeId, clientId }) {
		const topics = this.topics
		const currentCreativeId = String(topics.creativeId)
		const currentStreamIsResolved = topics.element.dataset.effectiveCreativeId ||
			topics.knownEffectiveCreativeIds.has(currentCreativeId)
		const subscribedToAnotherStream = topics.topicsSubscription && currentStreamIsResolved &&
			String(topics.effectiveCreativeId) !== String(effectiveCreativeId)
		const missedDuringDisconnect =
			topics.possiblyMissedPendingSelfEchoesDuringDisconnect.has(clientId)
		const missedWhileClosed =
			topics.possiblyMissedPendingSelfEchoes.has(clientId) && !topics.topicsSubscription

		return {
			missedDuringDisconnect,
			cannotArrive: missedWhileClosed || subscribedToAnotherStream || missedDuringDisconnect,
		}
	}

	_finish(context, outcome, claimed) {
		const topics = this.topics
		if (claimed && outcome.rejected) topics.releasePendingSelfEcho(context.clientId)
		if (claimed && outcome.saveResult === null) {
			topics.scheduleAmbiguousPendingSelfEchoRetirement(context.clientId)
		}
		const pendingPickMatches = topics.selectionState.pendingPickMatches(
			context.pendingPick,
			context.creativeId,
			outcome.topicId,
		)
		if (outcome.stale && pendingPickMatches) topics.selectionState.clearPendingPick()
		if (outcome.saveResult !== null) {
			topics.retryDeferredLastTopicReconciliation(context.effectiveCreativeId)
		}
		if (outcome.saveResult !== false && pendingPickMatches) {
			topics.selectionState.clearPendingPick()
		}
	}
}
