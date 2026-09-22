export default class TopicSelectionRestoreState {
    constructor() {
        this.epoch = 0
        this.explicitAllMessagesSelection = false
        this.pendingPick = undefined
        this.pickCreativeId = undefined
        this.pickTopicId = undefined
    }

    recordPick(creativeId, topicId, { pending = false } = {}) {
        this.epoch += 1
        this.pickCreativeId = creativeId
        this.pickTopicId = topicId
        if (pending) {
            this.pendingPick = { creativeId, topicId }
        }
    }

    outranks(epoch, creativeId, topics, archivedTopics) {
        const hasNewerPick = this.epoch !== epoch
        const hasUnsavedPick = this.pendingPick &&
            String(this.pendingPick.creativeId) === String(creativeId)
        if (!hasNewerPick && !hasUnsavedPick) return false
        if (String(this.pickCreativeId) !== String(creativeId)) return false
        if (!this.pickTopicId) return true

        return [ ...(topics || []), ...(archivedTopics || []) ]
            .some(topic => String(topic.id) === String(this.pickTopicId))
    }

    pendingPickMatches(pick, creativeId, topicId) {
        return this.pendingPick === pick &&
            String(pick?.creativeId) === String(creativeId) &&
            pick?.topicId === topicId
    }

    clearPendingPick(topicId = undefined) {
        if (topicId === undefined || String(this.pendingPick?.topicId) === String(topicId)) {
            this.pendingPick = null
        }
    }
}
