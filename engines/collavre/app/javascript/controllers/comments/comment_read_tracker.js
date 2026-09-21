import csrfFetch from '../../lib/api/csrf_fetch'

const READ_DEBOUNCE_MS = 2000

export default class CommentReadTracker {
  constructor(controller, { request = csrfFetch } = {}) {
    this.controller = controller
    this.request = request
  }

  resetRenderedSnapshot() {
    this.controller.renderedAllTopicIds = null
    this.controller.renderedAllTopicWatermarks = null
    this.controller.renderedAllIncludesLegacy = false
  }

  captureRenderedSnapshot(topicIds, topicWatermarks) {
    this.controller.renderedAllTopicIds = topicIds.split(',').filter(Boolean)
    try {
      this.controller.renderedAllTopicWatermarks = topicWatermarks ? JSON.parse(topicWatermarks) : null
      this.controller.renderedAllIncludesLegacy = Boolean(
        this.controller.renderedAllTopicWatermarks &&
        Object.hasOwn(this.controller.renderedAllTopicWatermarks, '_legacy')
      )
    } catch (_error) {
      this.controller.renderedAllTopicWatermarks = null
      this.controller.renderedAllIncludesLegacy = false
    }
  }

  markCommentsRead() {
    const controller = this.controller
    if (!controller.creativeId) return
    if (controller.markReadTimeout) window.clearTimeout(controller.markReadTimeout)

    const creativeId = controller.creativeId
    const topicId = controller.currentTopicId || null
    const topicIds = topicId ? null : controller.renderedAllTopicIds
    const topicWatermarks = topicId ? null : controller.renderedAllTopicWatermarks
    const pendingRead = { creativeId, topicId, topicIds, topicWatermarks }
    controller.pendingRead = pendingRead
    controller.markReadTimeout = window.setTimeout(() => {
      controller.markReadTimeout = null
      if (controller.pendingRead !== pendingRead) return
      controller.pendingRead = null
      if (!controller.element.isConnected || controller.creativeId !== creativeId ||
          (controller.currentTopicId || null) !== topicId) return

      this.updateReadPointer({ creativeId, topicId, topicIds, topicWatermarks })
    }, READ_DEBOUNCE_MS)
  }

  flushPendingRead({ keepalive = false } = {}) {
    const controller = this.controller
    const pendingRead = controller.pendingRead
    if (!pendingRead) return

    if (controller.markReadTimeout) window.clearTimeout(controller.markReadTimeout)
    controller.markReadTimeout = null
    controller.pendingRead = null
    this.updateReadPointer({ ...pendingRead, keepalive })
  }

  updateReadPointer({ creativeId, topicId, topicIds = null, topicWatermarks = null, keepalive = false }) {
    if (!creativeId) return

    this.request('/comment_read_pointers/update', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      keepalive,
      body: JSON.stringify({
        creative_id: creativeId,
        topic_id: topicId,
        ...(topicIds ? { topic_ids: topicIds } : {}),
        ...(topicWatermarks ? { topic_watermarks: topicWatermarks } : {}),
      }),
    }).then((response) => {
      const controller = this.controller
      if (!response.ok || !controller.element.isConnected || controller.creativeId !== creativeId ||
          (controller.currentTopicId || null) !== topicId) return

      controller.popupController?.topicsController?.loadTopics?.()
    }).catch(() => { /* ignore — creative may have been deleted */ })
  }

  recordRenderedAllTopicWatermarks(comments, { includeNewTopics = false } = {}) {
    const controller = this.controller
    if (controller.currentTopicId || !Array.isArray(controller.renderedAllTopicIds)) return false

    let addedTopic = false
    const renderedComments = comments instanceof Element ? [comments] : Array.from(comments || [])
    renderedComments.forEach((comment) => {
      const topicId = comment.dataset.topicId
      const commentId = Number.parseInt(comment.dataset.commentId, 10)
      if (!Number.isSafeInteger(commentId) || commentId <= 0) return

      const watermarkKey = topicId || '_legacy'
      if (!topicId && !controller.renderedAllIncludesLegacy) {
        if (!includeNewTopics) return

        controller.renderedAllIncludesLegacy = true
        addedTopic = true
      }

      if (topicId && !controller.renderedAllTopicIds.some((id) => String(id) === String(topicId))) {
        if (!includeNewTopics) return

        controller.renderedAllTopicIds.push(String(topicId))
        addedTopic = true
      }

      controller.renderedAllTopicWatermarks ||= {}
      const previousId = Number.parseInt(controller.renderedAllTopicWatermarks[watermarkKey], 10)
      if (!Number.isSafeInteger(previousId) || commentId > previousId) {
        controller.renderedAllTopicWatermarks[watermarkKey] = commentId
      }
    })

    return addedTopic
  }

  reportRenderedAllTopics() {
    const controller = this.controller
    if (controller.currentTopicId || !Array.isArray(controller.renderedAllTopicIds)) return

    controller.element.dispatchEvent(new CustomEvent('comments--list:rendered-all-topics', {
      bubbles: true,
      detail: {
        creativeId: controller.creativeId,
        topicIds: controller.renderedAllTopicIds,
        includesLegacy: controller.renderedAllIncludesLegacy,
      },
    }))
  }

  isOutsideRenderedAllTopics(topicId) {
    const topicIds = this.controller.renderedAllTopicIds
    return Array.isArray(topicIds) &&
      !topicIds.some((id) => String(id) === String(topicId))
  }
}
