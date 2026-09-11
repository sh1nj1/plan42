const LAST_TOPIC_SAVE_SESSION_STORAGE_KEY = "collavre:last-topic-save-session-id"
const LAST_TOPIC_SAVE_SEQUENCE_STORAGE_KEY = "collavre:last-topic-save-sequence"
const LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX = "collavre:last-topic-save-session:"
let fallbackClientIdSequence = 0

function newClientId() {
    if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()

    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
        const bytes = crypto.getRandomValues(new Uint8Array(16))
        return `save-${Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')}`
    }

    fallbackClientIdSequence += 1
    return `save-${Date.now().toString(36)}-${fallbackClientIdSequence.toString(36)}`
}

export default class LastTopicSaveOrderState {
    constructor() {
        this.timer = null
        this.chain = Promise.resolve()
        this.sessionId = undefined
        this.sequence = 0
        this.lastKnownRemoteTopicIds = new Map()
        this.highestRevisions = new Map()
        this.knownEffectiveCreativeIds = new Map()
        this.activeLoadAcknowledgementVersions = new Map()
        this.acknowledgementVersion = 0
        this.deferredReconciliations = new Set()
        this.subscriptionGenerations = new Map()
    }

    enqueue(callback) {
        this.chain = this.chain.then(callback)
        return this.chain
    }

    nextClientId() {
        this.sessionId ||= this.windowSessionId()
        this.sequence = this.nextSequence()
        return `${this.sessionId}.${this.sequence}.${newClientId()}`
    }

    windowSessionId() {
        try {
            const sessionId = this.currentWindowSessionId()
            sessionStorage.setItem(LAST_TOPIC_SAVE_SESSION_STORAGE_KEY, sessionId)
            return sessionId
        } catch (_) {
            return newClientId()
        }
    }

    currentWindowSessionId() {
        const currentName = window.name || ""
        if (currentName.startsWith(LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX)) {
            const sessionId = currentName.slice(LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX.length)
            if (/^[A-Za-z0-9-]+$/.test(sessionId)) return sessionId
        }

        const sessionId = newClientId()
        window.name = `${LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX}${sessionId}`
        return sessionId
    }

    nextSequence() {
        try {
            const stored = Number(sessionStorage.getItem(LAST_TOPIC_SAVE_SEQUENCE_STORAGE_KEY))
            const previous = Number.isSafeInteger(stored) && stored >= 0 ? stored : 0
            const sequence = Math.max(this.sequence, previous) + 1
            sessionStorage.setItem(LAST_TOPIC_SAVE_SEQUENCE_STORAGE_KEY, String(sequence))
            return sequence
        } catch (_) {
            return this.sequence + 1
        }
    }

    lastKnownTopicIdFor(creativeId) {
        return this.lastKnownRemoteTopicIds.get(String(creativeId))
    }

    setLastKnownTopicId(creativeId, value) {
        this.lastKnownRemoteTopicIds.set(String(creativeId), value ? String(value) : "")
    }

    observeRevision(creativeId, revision) {
        if (!revision) return true

        const streamCreativeId = String(creativeId)
        const previous = this.highestRevisions.get(streamCreativeId)
        const comparison = this.compareRevisions(revision, previous)
        if (comparison !== null && comparison < 0) return false
        if (comparison === null || comparison > 0) {
            this.highestRevisions.set(streamCreativeId, revision)
        }
        return true
    }

    normalizeRevision(value) {
        if (!Array.isArray(value) || value.length !== 2) return null
        const revision = value.map(Number)
        return revision.every(Number.isSafeInteger) ? revision : null
    }

    compareRevisions(left, right) {
        if (!left || !right) return null
        return left[0] === right[0] ? left[1] - right[1] : left[0] - right[0]
    }

    subscriptionGenerationFor(creativeId) {
        const streamCreativeId = String(creativeId)
        if (!this.subscriptionGenerations.has(streamCreativeId)) {
            this.subscriptionGenerations.set(streamCreativeId, 0)
        }
        return this.subscriptionGenerations.get(streamCreativeId)
    }

    bumpSubscriptionGeneration(creativeId) {
        const streamCreativeId = String(creativeId)
        this.subscriptionGenerations.set(
            streamCreativeId,
            this.subscriptionGenerationFor(streamCreativeId) + 1
        )
    }
}

export { LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX }
