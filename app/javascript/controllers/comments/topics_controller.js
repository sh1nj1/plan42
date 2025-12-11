import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
    static targets = ["list"]

    connect() {
        // Initial load if creativeId is available (e.g. from dataset if set server-side)
        if (this.creativeId) {
            this.loadTopics()
        }
    }

    onPopupOpened({ creativeId }) {
        this.creativeIdValue = creativeId
        return this.loadTopics()
    }

    onPopupClosed() {
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
        console.log("Loading topics for creative", this.creativeId)
        if (!this.creativeId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics`)
            if (response.ok) {
                const topics = await response.json()
                this.renderTopics(topics)
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
                this.select({ target: { dataset: { id: lastTopicId } } })
            }
        }
    }

    renderTopics(topics) {
        let html = `<span class="topic-tag ${this.currentTopicId ? '' : 'active'}" data-action="click->comments--topics#select" data-id="">#Main</span>`

        topics.forEach(topic => {
            // Ensure comparison handles string/number difference
            const isActive = String(this.currentTopicId) === String(topic.id) ? 'active' : ''
            html += `<span class="topic-tag ${isActive}" data-action="click->comments--topics#select" data-id="${topic.id}">#${topic.name}</span>`
        })

        // Add create button container
        html += `<span class="topic-creation-container" data-comments--topics-target="creationContainer">
              <button class="add-topic-btn" data-action="click->comments--topics#showInput">+</button>
             </span>`

        this.listTarget.innerHTML = html
    }

    showInput(event) {
        event.preventDefault()
        const container = this.element.querySelector('[data-comments--topics-target="creationContainer"]')
        if (!container) return

        container.innerHTML = `<input type="text" class="topic-input" placeholder="New Topic" 
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
        const id = event.target.dataset.id
        this.updateSelectionUI(id)
        // Dispatch event
        this.dispatch("change", { detail: { topicId: id } })
    }

    updateSelectionUI(id) {
        this.currentTopicId = id
        // Update UI
        this.listTarget.querySelectorAll('.topic-tag').forEach(el => {
            el.classList.toggle('active', String(el.dataset.id) === String(id))
        })
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
}
