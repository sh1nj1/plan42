export default class LastTopicSelfEchoState {
    constructor() {
        this.pendingIds = []
        this.creativeIds = new Map()
        this.topicIds = new Map()
        this.previousTopicIds = new Map()
        this.acknowledgementVersions = new Map()
        this.remoteRevisions = new Map()
        this.acknowledgedIds = new Set()
        this.settledIds = new Set()
        this.possiblyMissedIds = new Set()
        this.possiblyMissedDuringDisconnectIds = new Set()
        this.ambiguousRetirementTimers = new Map()
        this.retiredSequenceHighWaters = new Map()
    }

    claim(clientId, { creativeId, topicId, previousTopicId, possiblyMissed = false }) {
        this.pendingIds.push(clientId)
        this.creativeIds.set(clientId, String(creativeId))
        this.topicIds.set(clientId, topicId ? String(topicId) : "")
        this.previousTopicIds.set(clientId, previousTopicId ? String(previousTopicId) : "")
        if (possiblyMissed) this.possiblyMissedIds.add(clientId)
    }
}
