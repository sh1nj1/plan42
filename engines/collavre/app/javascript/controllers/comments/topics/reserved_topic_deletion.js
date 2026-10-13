export function reloadDeletedReservedTopic(controller, topicId) {
    const idKey = ['mainTopicId', 'systemTopicId'].find(key =>
        controller[key] && String(controller[key]) === String(topicId))
    if (!idKey) return false

    // Index recreates reserved topics and returns their replacement IDs.
    // Clear the old ID before notifying the message list or restoring a selection.
    controller[idKey] = null
    if (String(controller.currentTopicId) === String(topicId)) {
        controller.fallbackFromRemovedTopic(topicId)
        controller.dispatch("change", { detail: { topicId: "", mainTopicId: controller.mainTopicId } })
    }
    controller.loadTopics()
    return true
}
