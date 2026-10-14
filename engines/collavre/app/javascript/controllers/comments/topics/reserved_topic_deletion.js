export function reloadDeletedReservedTopic(controller, topicId) {
    const idKey = ['mainTopicId', 'systemTopicId'].find(key =>
        controller[key] && String(controller[key]) === String(topicId))
    if (!idKey) return false

    // Index recreates reserved topics and returns their replacement IDs.
    // Clear the old ID before notifying the message list or restoring a selection.
    controller[idKey] = null
    const wasSelected = String(controller.currentTopicId) === String(topicId)
    if (wasSelected) controller.fallbackFromRemovedTopic(topicId)
    if (wasSelected || idKey === 'mainTopicId') {
        controller.dispatch("change", { detail: controller.changeDetail(controller.currentTopicId) })
    }
    controller.loadTopics()
    return true
}

export function archivedTopicControls(controller, topic, canManage, restoreIcon) {
    if (!canManage || topic.read_only) return ''
    const reserved = ['mainTopicId', 'systemTopicId'].some(key =>
        controller[key] && String(controller[key]) === String(topic.id))
    return reserved
        ? `<button class="delete-topic-btn" data-action="click->comments--topics#deleteTopic" data-id="${topic.id}">&times;</button>`
        : `<button class="unarchive-topic-btn" data-action="click->comments--topics#unarchiveTopic" data-id="${topic.id}" title="Restore">${restoreIcon}</button>`
}
