import { Controller } from "@hotwired/stimulus"
import { createSubscription } from "../../services/cable"

export default class extends Controller {
    static targets = ["list"]

    connect() {
        this.topics = []
        this.canManageTopics = false
        this.subscribedCreativeId = null
        this.topicsSubscription = null
        // Initial load if creativeId is available (e.g. from dataset if set server-side)
        if (this.creativeId) {
            this.loadTopics()
            this.subscribe()
        }
        this.handleNewMessage = this.handleNewMessage.bind(this)
        window.addEventListener('comments--topics:new-message', this.handleNewMessage)
    }

    disconnect() {
        window.removeEventListener('comments--topics:new-message', this.handleNewMessage)
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
                this.topics = topics
                this.canManageTopics = canManage
                this.renderTopics(this.topics, this.canManageTopics)
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

        if (lastTopicId) {
            this.selectTopic("")
        }
    }

    renderTopics(topics, canManage = false) {
        let html = `<span class="topic-tag ${this.currentTopicId ? '' : 'active'}" data-action="click->comments--topics#select" data-id="">#Main</span>`

        topics.forEach(topic => {
            // Ensure comparison handles string/number difference
            const isActive = String(this.currentTopicId) === String(topic.id) ? 'active' : ''
            html += `<span class="topic-tag ${isActive}" data-action="click->comments--topics#select" data-id="${topic.id}">
                        #${topic.name}`

            if (canManage) {
                html += `<button class="delete-topic-btn" data-action="click->comments--topics#deleteTopic" data-id="${topic.id}">&times;</button>`
            }

            html += `</span>`
        })

        // Add create button container
        if (canManage) {
            html += `<span class="topic-creation-container" data-comments--topics-target="creationContainer">
                  <button class="add-topic-btn" data-action="click->comments--topics#showInput">+</button>
                 </span>`
        }

        this.listTarget.innerHTML = html
    }

    async deleteTopic(event) {
        event.stopPropagation()
        const confirmText = this.listTarget.dataset.confirmDeleteText || "This will delete all messages in this topic. Are you sure?"
        if (!confirm(confirmText)) return

        const topicId = event.target.dataset.id
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

        const id = event.currentTarget.dataset.id
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

    updateSelectionUI(id) {
        this.currentTopicId = id
        // Update UI
        this.listTarget.querySelectorAll('.topic-tag').forEach(el => {
            el.classList.toggle('active', String(el.dataset.id) === String(id))
            if (String(el.dataset.id) === String(id)) {
                el.classList.remove('has-new-messages')
            }
        })
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

        if (!data.topic) return

        const topics = this.topics || []
        const exists = topics.some((topic) => String(topic.id) === String(data.topic.id))
        if (exists) return

        this.topics = [...topics, data.topic]
        this.renderTopics(this.topics, this.canManageTopics)
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

        this.renderTopics(this.topics, this.canManageTopics)
        this.restoreSelection()
    }
}
