/**
 * Topics API helper — shared between topics_controller and topic_search_controller
 */

function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
}

/**
 * Fetch the next auto-generated topic name for a creative.
 * @param {string|number} creativeId
 * @returns {Promise<string|null>}
 */
export async function fetchNextTopicName(creativeId) {
    try {
        const response = await fetch(`/creatives/${creativeId}/topics/next_name`, {
            headers: { Accept: 'application/json' }
        })
        if (response.ok) {
            const data = await response.json()
            return data.name
        }
    } catch (e) {
        console.error('Error fetching next topic name', e)
    }
    return null
}

/**
 * Save the last selected topic for a creative (server-side persistence).
 * @param {string|number} creativeId
 * @param {string|number|null} topicId
 * @returns {Promise<boolean>}
 */
export async function saveLastTopic(creativeId, topicId) {
    try {
        const response = await fetch(`/creatives/${creativeId}/user_creative_preferences/update_last_topic`, {
            method: 'PATCH',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRF-Token': csrfToken()
            },
            body: JSON.stringify({ last_topic_id: topicId || null })
        })
        return response.ok
    } catch (e) {
        console.error('Error saving last topic', e)
        return false
    }
}

/**
 * Create a new topic and optionally move comments into it.
 * @param {string|number} creativeId
 * @param {string} name - topic name
 * @param {string[]|number[]} commentIds - comments to move (optional)
 * @returns {Promise<{ok: boolean, topic?: object, error?: string}>}
 */
/**
 * Branch (copy) selected comments into a new topic.
 * @param {string|number} creativeId
 * @param {string[]|number[]} commentIds
 * @param {string|number|null} topicId - source topic (null for Main)
 * @returns {Promise<{ok: boolean, topic?: object, error?: string}>}
 */
export async function branchComments(creativeId, commentIds, topicId = null) {
    try {
        const body = { comment_ids: commentIds }
        if (topicId) body.topic_id = topicId

        const response = await fetch(`/creatives/${creativeId}/comments/branch`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRF-Token': csrfToken()
            },
            body: JSON.stringify(body)
        })

        if (response.ok) {
            const data = await response.json()
            return { ok: true, topic: data.topic }
        } else {
            const data = await response.json().catch(() => ({}))
            return { ok: false, error: data.error || 'Failed to branch comments' }
        }
    } catch (e) {
        console.error('Error branching comments', e)
        return { ok: false, error: e.message }
    }
}

export async function createTopicWithComments(creativeId, name, commentIds = []) {
    try {
        const body = { topic: { name } }
        if (commentIds.length > 0) {
            body.comment_ids = commentIds
        }

        const response = await fetch(`/creatives/${creativeId}/topics`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRF-Token': csrfToken()
            },
            body: JSON.stringify(body)
        })

        if (response.ok) {
            const topic = await response.json()
            return { ok: true, topic }
        } else {
            const data = await response.json().catch(() => ({}))
            const error = (data.errors || [data.error]).filter(Boolean).join(', ') || 'Failed to create topic'
            return { ok: false, error }
        }
    } catch (e) {
        console.error('Error creating topic with comments', e)
        return { ok: false, error: e.message }
    }
}
