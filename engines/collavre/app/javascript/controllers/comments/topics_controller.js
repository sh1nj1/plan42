import { Controller } from "@hotwired/stimulus"
import { createSubscription } from "../../services/cable"

const ICON_ARCHIVE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg>`
const ICON_RESTORE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6.69 3L3 13"/></svg>`

export default class extends Controller {
    static targets = ["list"]

    connect() {
        this.topics = []
        this.canManageTopics = false
        this.canCreateTopic = false
        this.subscribedCreativeId = null
        this.topicsSubscription = null
        // Initial load if creativeId is available (e.g. from dataset if set server-side)
        if (this.creativeId) {
            this.loadTopics()
            this.subscribe()
        }
        this.handleNewMessage = this.handleNewMessage.bind(this)
        this.handleTopicMoved = this.handleTopicMoved.bind(this)
        window.addEventListener('comments--topics:new-message', this.handleNewMessage)
        window.addEventListener('collavre:topic-moved', this.handleTopicMoved)
    }

    disconnect() {
        window.removeEventListener('comments--topics:new-message', this.handleNewMessage)
        window.removeEventListener('collavre:topic-moved', this.handleTopicMoved)
        this.unsubscribe()
    }

    onPopupOpened({ creativeId }) {
        this.creativeIdValue = creativeId
        this.subscribe()
        return this.loadTopics()
    }

    onPopupClosed() {
        this.unsubscribe()
        this.creativeIdValue = null
    }

    get creativeId() {
        if (this.creativeIdValue) return this.creativeIdValue

        // Fallback: Check dataset (updated by popup controller)
        if (this.element.dataset.creativeId) return this.element.dataset.creativeId

        // Fallback: URL/DOM checks
        const treeUrl = document.getElementById("creatives")?.dataset?.creativesTreeUrlValue
        if (treeUrl) {
            const urlParams = new URLSearchParams(treeUrl.split('?')[1]);
            return urlParams.get('parent_id') || urlParams.get('id');
        }
        const match = window.location.pathname.match(/\/creatives\/(\d+)/)
        return match ? match[1] : null
    }

    async loadTopics() {
        if (!this.creativeId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics`)
            if (response.ok) {
                const data = await response.json()
                const topics = Array.isArray(data) ? data : data.topics
                const canManage = Array.isArray(data) ? false : data.can_manage
                const canCreateTopic = Array.isArray(data) ? false : (data.can_create_topic ?? canManage)
                this.topics = topics
                this.canManageTopics = canManage
                this.canCreateTopic = canCreateTopic
                this.archivedTopics = data.archived_topics || []

                this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)
                this.restoreSelection()
            }
        } catch (e) {
            console.error("Failed to load topics", e)
        }
    }

    restoreSelection() {
        const lastTopicId = this.currentTopicId
        if (lastTopicId) {
            // Validate it exists in list
            const exists = this.listTarget.querySelector(`[data-id="${lastTopicId}"]`)
            if (exists) {
                this.selectTopic(lastTopicId)
                return
            }
        }

        // Always dispatch change event to ensure form controller gets the correct topic.
        // Without this, switching to a creative with no stored topic leaves the form
        // controller with a stale topic_id from the previous creative.
        this.selectTopic("")
    }

    renderTopics(topics, canManage = false, canCreateTopic = canManage) {
        const dragActions = canManage
            ? 'dragstart->comments--topics#handleTopicDragStart dragend->comments--topics#handleTopicDragEnd'
            : ''
        const dropActions = 'dragover->comments--topics#handleDragOver dragleave->comments--topics#handleDragLeave drop->comments--topics#handleDrop'
        const topicDropActions = canManage
            ? 'dragover->comments--topics#handleTopicReorderDragOver dragleave->comments--topics#handleTopicReorderDragLeave drop->comments--topics#handleTopicReorderDrop'
            : ''

        let html = `<span class="topic-tag topic-drop-target ${this.currentTopicId ? '' : 'active'}" 
                          data-action="click->comments--topics#select ${dropActions}" 
                          data-id="">#Main</span>`

        topics.forEach(topic => {
            // Ensure comparison handles string/number difference
            const isActive = String(this.currentTopicId) === String(topic.id) ? 'active' : ''
            const draggable = canManage ? 'draggable="true"' : ''
            const agentAvatar = topic.primary_agent?.avatar_url
                ? `<img src="${this.escapeAttr(topic.primary_agent.avatar_url)}" class="topic-agent-avatar" alt="${this.escapeAttr(topic.primary_agent.name)}" title="${this.escapeAttr(topic.primary_agent.name)}">`
                : ''
            html += `<span class="topic-tag topic-drop-target ${isActive}" ${draggable}
                          data-action="click->comments--topics#select ${dropActions} ${dragActions} ${topicDropActions}" 
                          data-id="${topic.id}">
                        ${agentAvatar}#${topic.name}`

            if (canManage) {
                html += `<button class="archive-topic-btn" data-action="click->comments--topics#archiveTopic" data-id="${topic.id}" title="Archive">${ICON_ARCHIVE}</button>`
                html += `<button class="delete-topic-btn" data-action="click->comments--topics#deleteTopic" data-id="${topic.id}">&times;</button>`
            }

            html += `</span>`
        })

        // Archived topics section
        if (this.archivedTopics && this.archivedTopics.length > 0) {
            html += `<span class="topic-archived-toggle" data-action="click->comments--topics#toggleArchivedTopics">
                      ${ICON_ARCHIVE} ${this.archivedTopics.length}
                     </span>`
            if (this.showingArchived) {
                this.archivedTopics.forEach(topic => {
                    html += `<span class="topic-tag topic-archived" data-id="${topic.id}">
                              #${topic.name}
                              ${canManage ? `<button class="unarchive-topic-btn" data-action="click->comments--topics#unarchiveTopic" data-id="${topic.id}" title="Restore">${ICON_RESTORE}</button>` : ''}
                             </span>`
                })
            }
        }

        // Add create button container (write permission is sufficient for topic creation)
        if (canCreateTopic) {
            html += `<span class="topic-creation-container" data-comments--topics-target="creationContainer">
                  <button class="add-topic-btn" data-action="click->comments--topics#showInput">+</button>
                 </span>`
        }

        this.listTarget.innerHTML = html
    }

    handleDragOver(event) {
        // Only accept comment drops
        if (!event.dataTransfer.types.includes('application/x-comment-ids')) return

        event.preventDefault()
        event.dataTransfer.dropEffect = 'move'
        event.currentTarget.classList.add('drag-over')
    }

    handleDragLeave(event) {
        event.currentTarget.classList.remove('drag-over')
    }

    async handleDrop(event) {
        event.preventDefault()
        event.currentTarget.classList.remove('drag-over')

        const commentIdsJson = event.dataTransfer.getData('application/x-comment-ids')
        if (!commentIdsJson) return

        const commentIds = JSON.parse(commentIdsJson)
        if (!commentIds || commentIds.length === 0) return

        const targetTopicId = event.currentTarget.dataset.id // Empty string for Main

        // Dispatch event for list_controller to handle the move
        this.dispatch('move-to-topic', {
            detail: {
                commentIds,
                targetTopicId
            }
        })
    }

    // Topic reorder drag & drop handlers
    handleTopicDragStart(event) {
        const topicEl = event.currentTarget
        const topicId = topicEl.dataset.id
        if (!topicId) {
            event.preventDefault()
            return
        }

        this.draggingTopicId = topicId
        event.dataTransfer.setData('application/x-topic-id', topicId)
        // Include topic move data so creative tree rows can accept this drop
        event.dataTransfer.setData('application/x-topic-move', JSON.stringify({
            topicId,
            sourceCreativeId: this.creativeId
        }))
        event.dataTransfer.effectAllowed = 'move'

        requestAnimationFrame(() => {
            topicEl.classList.add('topic-dragging')
        })
    }

    handleTopicDragEnd(event) {
        this.draggingTopicId = null
        event.currentTarget.classList.remove('topic-dragging')
        this.listTarget.querySelectorAll('.topic-tag').forEach(el => {
            el.classList.remove('topic-drag-over-left', 'topic-drag-over-right')
        })
    }

    handleTopicReorderDragOver(event) {
        // Only accept topic reorder drops
        if (!event.dataTransfer.types.includes('application/x-topic-id')) return
        if (!this.draggingTopicId) return

        const targetEl = event.currentTarget
        const targetId = targetEl.dataset.id

        // Don't allow drop on self or Main
        if (!targetId || targetId === this.draggingTopicId) return

        event.preventDefault()
        event.dataTransfer.dropEffect = 'move'

        // Determine drop position (left or right) based on mouse position
        const rect = targetEl.getBoundingClientRect()
        const midpoint = rect.left + rect.width / 2
        const isLeft = event.clientX < midpoint

        targetEl.classList.toggle('topic-drag-over-left', isLeft)
        targetEl.classList.toggle('topic-drag-over-right', !isLeft)
    }

    handleTopicReorderDragLeave(event) {
        event.currentTarget.classList.remove('topic-drag-over-left', 'topic-drag-over-right')
    }

    async handleTopicReorderDrop(event) {
        event.preventDefault()

        const targetEl = event.currentTarget
        targetEl.classList.remove('topic-drag-over-left', 'topic-drag-over-right')

        const draggedTopicId = event.dataTransfer.getData('application/x-topic-id')
        const targetTopicId = targetEl.dataset.id

        if (!draggedTopicId || !targetTopicId || draggedTopicId === targetTopicId) return

        // Determine drop position
        const rect = targetEl.getBoundingClientRect()
        const midpoint = rect.left + rect.width / 2
        const insertBefore = event.clientX < midpoint

        // Reorder topics array
        const topics = [...this.topics]
        const draggedIndex = topics.findIndex(t => String(t.id) === String(draggedTopicId))
        const targetIndex = topics.findIndex(t => String(t.id) === String(targetTopicId))

        if (draggedIndex === -1 || targetIndex === -1) return

        // Remove dragged topic
        const [draggedTopic] = topics.splice(draggedIndex, 1)

        // Calculate new position
        let newIndex = targetIndex
        if (draggedIndex < targetIndex) {
            newIndex = insertBefore ? targetIndex - 1 : targetIndex
        } else {
            newIndex = insertBefore ? targetIndex : targetIndex + 1
        }

        // Insert at new position
        topics.splice(newIndex, 0, draggedTopic)

        // Update local state and UI immediately
        this.topics = topics
        this.renderTopics(topics, this.canManageTopics, this.canCreateTopic)
        this.restoreSelection()

        // Send to server
        await this.saveTopicOrder(topics.map(t => t.id))
    }

    async saveTopicOrder(topicIds) {
        if (!this.creativeId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics/reorder`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                },
                body: JSON.stringify({ topic_ids: topicIds })
            })

            if (!response.ok) {
                console.error('Failed to save topic order')
                // Reload to restore server state
                this.loadTopics()
            }
        } catch (e) {
            console.error('Error saving topic order', e)
            this.loadTopics()
        }
    }

    async deleteTopic(event) {
        event.stopPropagation()
        const confirmText = this.listTarget.dataset.confirmDeleteText || "This will delete all messages in this topic. Are you sure?"
        if (!confirm(confirmText)) return

        const topicId = event.currentTarget.dataset.id
        if (!topicId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics/${topicId}`, {
                method: 'DELETE',
                headers: {
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                }
            })

            if (response.ok) {
                if (String(this.currentTopicId) === String(topicId)) {
                    this.currentTopicId = "" // Switch to Main
                    this.dispatch("change", { detail: { topicId: "" } })
                }
                this.loadTopics()
            } else {
                alert("Failed to delete topic")
            }
        } catch (e) {
            console.error("Error deleting topic", e)
        }
    }

    async archiveTopic(event) {
        event.stopPropagation()
        const topicId = event.currentTarget.dataset.id
        if (!topicId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics/${topicId}/archive`, {
                method: 'PATCH',
                headers: {
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                }
            })

            if (response.ok) {
                if (String(this.currentTopicId) === String(topicId)) {
                    this.currentTopicId = ""
                    this.dispatch("change", { detail: { topicId: "" } })
                }
                this.loadTopics()
            } else {
                alert("Failed to archive topic")
            }
        } catch (e) {
            console.error("Error archiving topic", e)
        }
    }

    async unarchiveTopic(event) {
        event.stopPropagation()
        const topicId = event.currentTarget.dataset.id
        if (!topicId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics/${topicId}/unarchive`, {
                method: 'PATCH',
                headers: {
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                }
            })

            if (response.ok) {
                this.loadTopics()
            } else {
                alert("Failed to restore topic")
            }
        } catch (e) {
            console.error("Error restoring topic", e)
        }
    }

    toggleArchivedTopics(event) {
        event.stopPropagation()
        this.showingArchived = !this.showingArchived
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)
        this.restoreSelection()
    }

    showInput(event) {
        event.preventDefault()
        const container = this.element.querySelector('[data-comments--topics-target="creationContainer"]')
        if (!container) return

        const placeholder = this.listTarget.dataset.newTopicPlaceholder || "New Topic"
        container.innerHTML = `<input type="text" class="topic-input" placeholder="${placeholder}" 
                                  data-action="keydown->comments--topics#handleInputKey blur->comments--topics#resetInput"
                                  data-comments--topics-target="input">`

        const input = container.querySelector('input')
        requestAnimationFrame(() => input.focus())
    }

    resetInput() {
        // Small delay to allow enter key to process first if that was the cause
        setTimeout(() => {
            const container = this.element.querySelector('[data-comments--topics-target="creationContainer"]')
            if (container && !this.creating) {
                container.innerHTML = `<button class="add-topic-btn" data-action="click->comments--topics#showInput">+</button>`
            }
        }, 200)
    }

    handleInputKey(event) {
        if (event.key === 'Enter') {
            event.preventDefault()
            const name = event.target.value.trim()
            if (name) {
                this.createTopic(name)
            } else {
                this.resetInput()
            }
        } else if (event.key === 'Escape') {
            this.resetInput()
        }
    }

    select(event) {
        // Ignore if clicking on delete button (though stopPropagation should handle it)
        if (event.target.closest('.delete-topic-btn')) return
        // Ignore if clicking on edit input
        if (event.target.closest('.topic-edit-input')) return

        const id = event.currentTarget.dataset.id

        // If clicking on already active topic (not Main), show edit mode
        if (id && String(this.currentTopicId) === String(id) && this.canManageTopics) {
            this.showEditInput(event.currentTarget, id)
            return
        }

        this.selectTopic(id)
    }

    selectTopic(id) {
        this.updateSelectionUI(id)
        if (id) {
            this.clearNewMessageBadge(id)
        }
        // Dispatch event
        this.dispatch("change", { detail: { topicId: id } })
    }

    showEditInput(topicEl, topicId) {
        const topic = this.topics.find(t => String(t.id) === String(topicId))
        if (!topic) return

        const currentName = topic.name

        // Store original HTML for restore
        topicEl.dataset.originalHtml = topicEl.innerHTML

        // Replace content with input
        topicEl.innerHTML = `<input type="text" class="topic-edit-input" value="${currentName}"
                              data-action="keydown->comments--topics#handleEditKey blur->comments--topics#cancelEdit"
                              data-topic-id="${topicId}">`

        const input = topicEl.querySelector('input')
        requestAnimationFrame(() => {
            input.focus()
            input.select()
        })
    }

    handleEditKey(event) {
        if (event.key === 'Enter') {
            event.preventDefault()
            const name = event.target.value.trim()
            const topicId = event.target.dataset.topicId
            if (name) {
                this.updateTopic(topicId, name)
            } else {
                this.cancelEdit(event)
            }
        } else if (event.key === 'Escape') {
            event.preventDefault()
            this.cancelEdit(event)
        }
    }

    cancelEdit(event) {
        // Prevent blur from firing multiple times
        if (this.editCancelling) return
        this.editCancelling = true

        const topicEl = event.target.closest('.topic-tag')
        if (topicEl && topicEl.dataset.originalHtml) {
            topicEl.innerHTML = topicEl.dataset.originalHtml
            delete topicEl.dataset.originalHtml
        }

        setTimeout(() => { this.editCancelling = false }, 100)
    }

    async updateTopic(topicId, name) {
        if (!this.creativeId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics/${topicId}`, {
                method: 'PATCH',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                },
                body: JSON.stringify({ topic: { name } })
            })

            if (response.ok) {
                const updatedTopic = await response.json()
                // Update local topics array
                const index = this.topics.findIndex(t => String(t.id) === String(topicId))
                if (index !== -1) {
                    this.topics[index] = updatedTopic
                }
                this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)
                this.restoreSelection()
            } else {
                alert("Failed to update topic")
                this.loadTopics() // Reload to restore state
            }
        } catch (e) {
            console.error("Error updating topic", e)
            this.loadTopics()
        }
    }

    updateSelectionUI(id) {
        this.currentTopicId = id
        // Update UI
        let activeEl = null
        this.listTarget.querySelectorAll('.topic-tag').forEach(el => {
            const isActive = String(el.dataset.id) === String(id)
            el.classList.toggle('active', isActive)
            if (isActive) {
                el.classList.remove('has-new-messages')
                activeEl = el
            }
        })
        // Scroll active topic into view
        if (activeEl) {
            activeEl.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' })
        }
    }

    scrollToActiveTopic() {
        const activeEl = this.listTarget.querySelector('.topic-tag.active')
        if (activeEl) {
            activeEl.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' })
        }
    }

    handleTopicMoved(event) {
        const { sourceCreativeId, topicId } = event.detail
        // Reload topics if the moved topic belonged to the currently viewed creative
        if (String(sourceCreativeId) === String(this.creativeId)) {
            // If we were viewing the moved topic, switch to Main
            if (String(this.currentTopicId) === String(topicId)) {
                this.currentTopicId = ""
                this.dispatch("change", { detail: { topicId: "" } })
            }
            this.loadTopics()
        }
    }

    handleNewMessage(event) {
        const topicId = event.detail.topicId
        if (!topicId) return

        // Don't show badge if we are currently in this topic (shouldn't happen due to list_controller logic, but safety check)
        if (String(this.currentTopicId) === String(topicId)) return

        const topicEl = this.listTarget.querySelector(`.topic-tag[data-id="${topicId}"]`)
        if (topicEl) {
            topicEl.classList.add('has-new-messages')
        }
    }

    clearNewMessageBadge(topicId) {
        const topicEl = this.listTarget.querySelector(`.topic-tag[data-id="${topicId}"]`)
        if (topicEl) {
            topicEl.classList.remove('has-new-messages')
        }
    }

    async createTopic(name) {
        if (!this.creativeId) return

        this.creating = true // Prevent blur from resetting immediately

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                },
                body: JSON.stringify({ topic: { name } })
            })

            if (response.ok) {
                const topic = await response.json()
                this.currentTopicId = topic.id
                await this.loadTopics()
                // Dispatch change event manually since we skipped the click handler
                this.dispatch("change", { detail: { topicId: topic.id } })
            } else {
                alert("Failed to create topic")
            }
        } catch (e) {
            console.error("Error creating topic", e)
        } finally {
            this.creating = false
        }
    }

    get currentTopicId() {
        const urlParams = new URLSearchParams(window.location.search)
        const urlTopicId = urlParams.get('topic_id')
        if (urlTopicId) return urlTopicId

        return localStorage.getItem(`collavre_creative_${this.creativeId}_last_topic`) || ""
    }

    set currentTopicId(id) {
        if (id) {
            localStorage.setItem(`collavre_creative_${this.creativeId}_last_topic`, id)
        } else {
            localStorage.removeItem(`collavre_creative_${this.creativeId}_last_topic`)
        }
    }

    subscribe() {
        const creativeId = this.creativeId
        if (!creativeId) return

        if (this.topicsSubscription && this.subscribedCreativeId === String(creativeId)) return

        this.unsubscribe()

        this.subscribedCreativeId = String(creativeId)
        this.topicsSubscription = createSubscription(
            { channel: 'TopicsChannel', creative_id: this.creativeId },
            {
                received: (data) => this.handleTopicMessage(data)
            }
        )
    }

    unsubscribe() {
        if (this.topicsSubscription) {
            this.topicsSubscription.unsubscribe()
            this.topicsSubscription = null
        }
        this.subscribedCreativeId = null
    }

    handleTopicMessage(data) {
        if (!data) return

        const action = data.action || "created"
        if (action === "deleted") {
            this.removeTopic(data.topic_id)
            return
        }

        if (action === "updated" && data.topic) {
            this.updateTopicInList(data.topic)
            return
        }

        if (action === "archived" || action === "unarchived") {
            this.loadTopics()
            return
        }

        if (action === "reordered" && data.topic_ids) {
            this.reorderTopicsFromServer(data.topic_ids)
            return
        }

        if (!data.topic) return

        const topics = this.topics || []
        const exists = topics.some((topic) => String(topic.id) === String(data.topic.id))
        if (exists) return

        this.topics = [...topics, data.topic]
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)

        // Auto-select the new topic if created by the current user
        const currentUserId = document.body.dataset.currentUserId
        if (data.user_id && currentUserId && String(data.user_id) === String(currentUserId)) {
            this.selectTopic(String(data.topic.id))
        } else {
            this.restoreSelection()
        }
    }

    reorderTopicsFromServer(topicIds) {
        if (!topicIds || !Array.isArray(topicIds)) return

        const reorderedTopics = []
        topicIds.forEach(id => {
            const topic = this.topics.find(t => String(t.id) === String(id))
            if (topic) reorderedTopics.push(topic)
        })

        // Add any topics not in the list (shouldn't happen, but safety)
        this.topics.forEach(topic => {
            if (!reorderedTopics.find(t => String(t.id) === String(topic.id))) {
                reorderedTopics.push(topic)
            }
        })

        this.topics = reorderedTopics
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)
        this.restoreSelection()
    }

    updateTopicInList(updatedTopic) {
        const topics = this.topics || []
        const index = topics.findIndex(t => String(t.id) === String(updatedTopic.id))
        if (index === -1) return

        this.topics[index] = updatedTopic
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)
        this.restoreSelection()
    }

    removeTopic(topicId) {
        if (!topicId) return

        const topics = this.topics || []
        const nextTopics = topics.filter((topic) => String(topic.id) !== String(topicId))
        if (nextTopics.length === topics.length) return

        this.topics = nextTopics
        if (String(this.currentTopicId) === String(topicId)) {
            this.currentTopicId = ""
            this.dispatch("change", { detail: { topicId: "" } })
        }

        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic)
        this.restoreSelection()
    }

    escapeAttr(str) {
        if (!str) return ''
        return str.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    }
}
