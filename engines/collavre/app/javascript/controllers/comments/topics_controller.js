import { Controller } from "@hotwired/stimulus"
import { createSubscription } from "../../services/cable"
import { fetchNextTopicName, createTopicWithComments, saveLastTopic } from "../../lib/api/topics"
import { alertDialog, confirmDialog } from "../../lib/utils/dialog"

const ICON_ARCHIVE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg>`
const ICON_RESTORE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6.69 3L3 13"/></svg>`

export default class extends Controller {
    static targets = ["list", "creationContainer"]

    connect() {
        this.topics = []
        this.canManageTopics = false
        this.canCreateTopic = false
        this.canSetPrimaryAgent = false
        this.subscribedCreativeId = null
        this.topicsSubscription = null
        this._loadTopicsVersion = 0
        // Initial load if creativeId is available (e.g. from dataset if set server-side)
        if (this.creativeId && this.element.dataset.docked !== 'true') {
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
        // Clear stale cached state from the previous creative — otherwise
        // chat-context autofill (command_menu) reads stale values during the
        // window between popup switch and the new topics fetch completing.
        // form_controller's currentTopicId is cleared upstream in
        // popup_controller.notifyChildControllers; here we clear our own
        // mainTopicId (read directly as the autofill fallback) and the cached
        // effective_creative_id. loadTopics() repopulates both.
        delete this.element.dataset.effectiveCreativeId
        this.mainTopicId = null
        // Switching creatives reuses this instance without an onPopupClosed
        // (popup_controller._navigateToEntry calls open()/openForCreative()
        // again), so unread marks from the previous creative would badge the new
        // creative's archived toggle — and never clear, since those ids are not
        // among its topics.
        this.archivedWithNewMessages.clear()
        this.subscribe()
        return this.loadTopics()
    }

    onPopupClosed() {
        this._loadTopicsVersion += 1
        this.unsubscribe()
        this.creativeIdValue = null
        this.topics = []
        this.mainTopicId = null
        this.archivedWithNewMessages.clear()
        delete this.element.dataset.effectiveCreativeId
    }

    // Archived topics still accept messages, but their chips only exist in the
    // DOM while the archived section is expanded. Remember which ones have
    // unread traffic so the badge can live on the collapsed toggle and survive
    // re-renders. Created lazily: a docked controller can receive popup
    // lifecycle callbacks before connect() has run.
    get archivedWithNewMessages() {
        if (!this._archivedWithNewMessages) this._archivedWithNewMessages = new Set()
        return this._archivedWithNewMessages
    }

    // The toggle badge is derived from set size, so an id that is no longer
    // archived — unarchived, deleted, or left behind by a creative switch —
    // would keep it lit with no chip to click and clear it.
    pruneArchivedBadges() {
        if (this.archivedWithNewMessages.size === 0) return
        const archivedIds = new Set((this.archivedTopics || []).map(t => String(t.id)))
        this.archivedWithNewMessages.forEach(id => {
            if (!archivedIds.has(id)) this.archivedWithNewMessages.delete(id)
        })
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

        const version = ++this._loadTopicsVersion
        // Clear stale topics from previous creative to prevent name-based
        // dedupe in handleTopicMessage from blocking valid broadcasts
        this.topics = []

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics`)
            // Discard stale response if a newer loadTopics() call was made
            if (version !== this._loadTopicsVersion) return

            if (response.status === 404) {
                throw new Error(`Creative ${this.creativeId} not found`)
            }
            if (response.ok) {
                const data = await response.json()
                const topics = Array.isArray(data) ? data : data.topics
                const canManage = Array.isArray(data) ? false : data.can_manage
                const canCreateTopic = Array.isArray(data) ? false : (data.can_create_topic ?? canManage)
                // Assigning an agent is authorized at :write, not :admin, so the
                // release control must follow the same capability — otherwise a
                // write collaborator can pin an agent by drag-and-drop and then
                // has no way to undo it. Falls back to canManage for a server
                // that predates the field.
                const canSetPrimaryAgent = Array.isArray(data) ? false : (data.can_set_primary_agent ?? canManage)
                this.topics = topics
                this.canManageTopics = canManage
                this.canCreateTopic = canCreateTopic
                this.canSetPrimaryAgent = canSetPrimaryAgent
                this.archivedTopics = data.archived_topics || []
                this.pruneArchivedBadges()
                this.serverLastTopicId = data.last_topic_id ? String(data.last_topic_id) : ""
                this.isInbox = !!data.is_inbox
                this.systemTopicId = data.system_topic_id ? String(data.system_topic_id) : null
                this.mainTopicId = data.main_topic_id ? String(data.main_topic_id) : null
                // Expose effective origin id so chat-context autofill (slash commands)
                // and any other consumer can target the same creative the server uses
                // (linked creatives resolve params[:creative_id] through effective_origin).
                if (data.effective_creative_id) {
                    this.element.dataset.effectiveCreativeId = String(data.effective_creative_id)
                }

                // Migrate localStorage to server if server has no value
                this.migrateLocalStorage()

                this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
                this.restoreSelection()
            }
        } catch (e) {
            console.error("Failed to load topics", e)
            throw e
        }
    }

    restoreSelection() {
        const lastTopicId = this.currentTopicId
        if (lastTopicId) {
            // Validate against the topic data, not the rendered DOM. An archived
            // topic is still readable and writable — archiving hides it from the
            // strip, it does not close the conversation. A DOM lookup would bounce
            // the user back to Main every time the archived section is collapsed,
            // because collapsed chips are never rendered. selectTopic expands the
            // section when the selection lands inside it.
            const known = [ ...(this.topics || []), ...(this.archivedTopics || []) ]
            if (known.some(t => String(t.id) === String(lastTopicId))) {
                this.selectTopic(lastTopicId)
                return
            }
        }

        this.selectTopic(this.mainTopicId || "")
    }

    // An archived topic can be opened from the topic strip, the topic-list popup,
    // a deep link, or a restored last-topic. Expand the archived section from this
    // one choke point so the strip always shows which topic is open.
    revealArchivedTopic(id) {
        if (!id || this.showingArchived) return
        if (!(this.archivedTopics || []).some(t => String(t.id) === String(id))) return

        this.showingArchived = true
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
    }

    renderTopics(topics, canManage = false, canCreateTopic = canManage, canSetPrimaryAgent = canManage) {
        const dragActions = canManage
            ? 'dragstart->comments--topics#handleTopicDragStart dragend->comments--topics#handleTopicDragEnd'
            : ''
        const dropActions = 'dragover->comments--topics#handleDragOver dragleave->comments--topics#handleDragLeave drop->comments--topics#handleDrop'
        const topicDropActions = canManage
            ? 'dragover->comments--topics#handleTopicReorderDragOver dragleave->comments--topics#handleTopicReorderDragLeave drop->comments--topics#handleTopicReorderDrop'
            : ''

        const allMessagesLabel = this.element.dataset.topicMainText || 'All Messages'

        const mainTopic = this.mainTopicId ? topics.find(t => String(t.id) === String(this.mainTopicId)) : null
        const otherTopics = topics.filter(t => !mainTopic || String(t.id) !== String(this.mainTopicId))

        let html = ''

        const renderTopic = (topic) => {
            const isActive = String(this.currentTopicId) === String(topic.id) ? 'active' : ''
            const draggable = canManage ? 'draggable="true"' : ''
            // agent_locked marks a live agent session topic, whose primary agent is
            // session identity rather than a routing pin — the server refuses to
            // change it, so the avatar must not offer to release it.
            const releasableTopicId = canSetPrimaryAgent && !topic.agent_locked ? topic.id : null
            const agentAvatar = topic.primary_agent
                ? this.renderAgentAvatar(topic.primary_agent, releasableTopicId)
                : ''
            const branchIcon = topic.source_topic_id ? '<span class="topic-branch-icon" title="Branched">↗</span>' : ''
            const isMainTopic = this.mainTopicId && String(topic.id) === String(this.mainTopicId)
            let s = `<span class="topic-tag topic-drop-target ${isActive}" ${draggable}
                          data-action="click->comments--topics#select ${dropActions} ${dragActions} ${topicDropActions}"
                          data-id="${topic.id}"${topic.source_topic_id ? ` data-source-topic-id="${topic.source_topic_id}"` : ''}>
                        ${agentAvatar}${branchIcon}#${topic.name}`
            if (canManage && !isMainTopic) {
                s += `<button class="archive-topic-btn" data-action="click->comments--topics#archiveTopic" data-id="${topic.id}" title="Archive">${ICON_ARCHIVE}</button>`
                s += `<button class="delete-topic-btn" data-action="click->comments--topics#deleteTopic" data-id="${topic.id}">&times;</button>`
            }
            s += `</span>`
            return s
        }

        if (mainTopic) html += renderTopic(mainTopic)
        otherTopics.forEach(topic => { html += renderTopic(topic) })

        html += `<span class="topic-tag topic-drop-target topic-all-messages ${this.currentTopicId ? '' : 'active'}"
                      data-action="click->comments--topics#select ${dropActions}"
                      data-id="">📋 ${allMessagesLabel}</span>`

        // Archived topics section
        if (this.archivedTopics && this.archivedTopics.length > 0) {
            // Badges are re-applied from state on every render because innerHTML
            // below wipes the classes set by handleNewMessage.
            const toggleBadge = this.archivedWithNewMessages.size > 0 ? ' has-new-messages' : ''
            html += `<span class="topic-archived-toggle${toggleBadge}" data-action="click->comments--topics#toggleArchivedTopics">
                      ${ICON_ARCHIVE} ${this.archivedTopics.length}
                     </span>`
            if (this.showingArchived) {
                this.archivedTopics.forEach(topic => {
                    const isActive = String(this.currentTopicId) === String(topic.id) ? ' active' : ''
                    const hasNew = this.archivedWithNewMessages.has(String(topic.id)) ? ' has-new-messages' : ''
                    html += `<span class="topic-tag topic-archived${isActive}${hasNew}"
                                   data-action="click->comments--topics#select"
                                   data-id="${topic.id}">
                              #${topic.name}
                              ${canManage ? `<button class="unarchive-topic-btn" data-action="click->comments--topics#unarchiveTopic" data-id="${topic.id}" title="Restore">${ICON_RESTORE}</button>` : ''}
                             </span>`
                })
            }
        }

        this.listTarget.innerHTML = html

        // The create button lives outside the scrolling strip so it stays reachable
        // without horizontal scrolling, no matter how many topics there are.
        this.renderCreationContainer(canCreateTopic)
    }

    // Write permission is sufficient for topic creation.
    renderCreationContainer(canCreateTopic) {
        if (!this.hasCreationContainerTarget) return
        const container = this.creationContainerTarget

        container.hidden = !canCreateTopic
        if (!canCreateTopic) {
            container.innerHTML = ''
            return
        }

        // renderTopics re-runs on every topic broadcast; don't wipe a name being typed.
        // `creating` marks an already-submitted name, whose input must give way to the button.
        // A draft only survives re-renders of the creative it was typed for: chat-nav
        // switches creatives without blurring, and posting it there is the wrong creative.
        const draftIsCurrent = String(this._draftCreativeId) === String(this.creativeId)
        if (!this.creating && draftIsCurrent && container.querySelector('.topic-input')) return

        this.renderAddButton()
    }

    renderAddButton() {
        this.creationContainerTarget.innerHTML =
            `<button class="add-topic-btn" data-action="click->comments--topics#showInput">+</button>`
    }

    handleDragOver(event) {
        // Accept comment drops or agent drops
        const isComment = event.dataTransfer.types.includes('application/x-comment-ids')
        const isAgent = event.dataTransfer.types.includes('application/x-agent-drop')
        if (!isComment && !isAgent) return

        event.preventDefault()
        event.dataTransfer.dropEffect = isAgent ? 'copy' : 'move'
        event.currentTarget.classList.add('drag-over')
    }

    handleDragLeave(event) {
        event.currentTarget.classList.remove('drag-over')
    }

    async handleDrop(event) {
        event.preventDefault()
        event.currentTarget.classList.remove('drag-over')

        // Handle agent drop
        const agentJson = event.dataTransfer.getData('application/x-agent-drop')
        if (agentJson) {
            const agent = JSON.parse(agentJson)
            const targetTopicId = event.currentTarget.dataset.id || this.mainTopicId
            if (targetTopicId) {
                await this.setTopicPrimaryAgent(targetTopicId, agent)
            }
            return
        }

        // Handle comment drop
        const commentIdsJson = event.dataTransfer.getData('application/x-comment-ids')
        if (!commentIdsJson) return

        const commentIds = JSON.parse(commentIdsJson)
        if (!commentIds || commentIds.length === 0) return

        const targetTopicId = event.currentTarget.dataset.id || this.mainTopicId

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
        this.renderTopics(topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
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
        // Capture the topic id BEFORE awaiting the dialog: once the click
        // dispatch completes, event.currentTarget is reset to null, so reading
        // it after `await` throws. confirmDialog made this handler async, which
        // exposed the latent stale-currentTarget hazard (the old sync confirm()
        // never yielded the event loop).
        const topicId = event.currentTarget.dataset.id
        const confirmText = this.listTarget.dataset.confirmDeleteText || "This will delete all messages in this topic. Are you sure?"
        if (!(await confirmDialog(confirmText, { danger: true }))) return

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
                    this.dispatch("change", { detail: { topicId: "", mainTopicId: this.mainTopicId } })
                }
                this.loadTopics()
            } else {
                alertDialog(this._i18n("delete_error"))
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
                    this.dispatch("change", { detail: { topicId: "", mainTopicId: this.mainTopicId } })
                }
                this.loadTopics()
            } else {
                alertDialog(this._i18n("archive_error"))
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
                alertDialog(this._i18n("restore_error"))
            }
        } catch (e) {
            console.error("Error restoring topic", e)
        }
    }

    toggleArchivedTopics(event) {
        event.stopPropagation()
        this.showingArchived = !this.showingArchived
        // No restoreSelection() here: toggling cannot invalidate the selection, and
        // renderTopics already re-applies the active class. Re-selecting would
        // re-expand the section the user just collapsed (selectTopic reveals an
        // archived selection) and pointlessly reload the message list.
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
    }

    openTopicListPopup(event) {
        const btnRect = event.currentTarget.getBoundingClientRect()

        const openWith = (popup) => {
            popup.openForTopics(
                {
                    topics: this.topics || [],
                    archivedTopics: this.archivedTopics || [],
                    mainTopicId: this.mainTopicId,
                    allMessagesLabel: this.element.dataset.topicMainText || 'All Messages'
                },
                btnRect,
                (item) => this.selectTopic(item.id),
                this.element
            )
        }

        let modal = document.getElementById('topic-list-modal')
        if (modal) {
            const popup = this.application.getControllerForElementAndIdentifier(modal, 'topic-list')
            if (popup) openWith(popup)
            return
        }

        modal = document.createElement('div')
        modal.id = 'topic-list-modal'
        modal.className = 'common-popup'
        modal.style.display = 'none'
        modal.dataset.controller = 'topic-list'
        modal.innerHTML = `
          <button type="button" class="popup-close-btn" data-topic-list-target="close">&times;</button>
          <input type="text" class="shared-input-surface" style="width:100%;margin-bottom:0.5em;"
            placeholder="${this.element.dataset.topicSearchPlaceholderText || 'Search topics...'}"
            data-topic-list-target="input">
          <ul class="common-popup-list" data-popup-list data-topic-list-target="list"></ul>
        `
        // Append into the chat box (this.element === #comments-popup) so the popup
        // is caged within it and shares its stacking context.
        this.element.appendChild(modal)

        requestAnimationFrame(() => {
            const popup = this.application.getControllerForElementAndIdentifier(modal, 'topic-list')
            if (popup) openWith(popup)
            else console.error('topic-list controller not found after creation')
        })
    }

    showInput(event) {
        event.preventDefault()
        if (!this.hasCreationContainerTarget) return
        const container = this.creationContainerTarget

        this._draftCreativeId = this.creativeId
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
            if (this.hasCreationContainerTarget && !this.creating) {
                this.renderAddButton()
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

        // Navigate to source topic when clicking branch icon
        if (event.target.closest('.topic-branch-icon')) {
            const sourceTopicId = event.currentTarget.dataset.sourceTopicId
            if (sourceTopicId) {
                this.selectTopic(sourceTopicId)
                return
            }
        }

        const id = event.currentTarget.dataset.id

        // If clicking on already active topic (not Main), show edit mode
        if (id && String(this.currentTopicId) === String(id) && this.canManageTopics) {
            this.showEditInput(event.currentTarget, id)
            return
        }

        this.selectTopic(id)
    }

    selectTopic(id) {
        this.revealArchivedTopic(id)
        this.updateSelectionUI(id)
        if (id) {
            this.clearNewMessageBadge(id)
        }
        // Dispatch event
        this.dispatch("change", { detail: { topicId: id, isInbox: this.isInbox, systemTopicId: this.systemTopicId, mainTopicId: this.mainTopicId } })
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
                const index = this.topics.findIndex(t => String(t.id) === String(topicId))
                if (index !== -1) {
                    this.topics[index] = { ...this.topics[index], ...updatedTopic }
                }
                this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
                this.restoreSelection()
            } else {
                alertDialog(this._i18n("update_error"))
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
                this.dispatch("change", { detail: { topicId: "", mainTopicId: this.mainTopicId } })
            }
            this.loadTopics()
        }
    }

    handleNewMessage(event) {
        const topicId = event.detail.topicId
        if (!topicId) return

        // Don't show badge if we are currently in this topic (shouldn't happen due to list_controller logic, but safety check)
        if (String(this.currentTopicId) === String(topicId)) return

        const isArchived = (this.archivedTopics || []).some(t => String(t.id) === String(topicId))
        if (isArchived) this.archivedWithNewMessages.add(String(topicId))

        const topicEl = this.listTarget.querySelector(`.topic-tag[data-id="${topicId}"]`)
        if (topicEl) topicEl.classList.add('has-new-messages')

        // A collapsed archived section has no chip to badge, so the toggle carries
        // the notice — otherwise a message in an archived topic is invisible.
        if (isArchived) {
            this.listTarget.querySelector('.topic-archived-toggle')?.classList.add('has-new-messages')
        }
    }

    clearNewMessageBadge(topicId) {
        const topicEl = this.listTarget.querySelector(`.topic-tag[data-id="${topicId}"]`)
        if (topicEl) {
            topicEl.classList.remove('has-new-messages')
        }

        // The toggle aggregates every archived topic, so it only clears once none
        // of them is left unread.
        if (this.archivedWithNewMessages.delete(String(topicId)) && this.archivedWithNewMessages.size === 0) {
            this.listTarget.querySelector('.topic-archived-toggle')?.classList.remove('has-new-messages')
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
                // Flush save immediately so loadTopics gets the correct value from server
                await this.flushSaveLastTopic(topic.id)
                await this.loadTopics()
                // Dispatch change event manually since we skipped the click handler
                this.dispatch("change", { detail: { topicId: topic.id, mainTopicId: this.mainTopicId } })
            } else {
                alertDialog(this._i18n("create_error"))
            }
        } catch (e) {
            console.error("Error creating topic", e)
        } finally {
            this.creating = false
        }
    }

    // Priority: overrideTopicId (one-shot, set by deep-link) → URL topic_id → serverLastTopicId.
    // overrideTopicId is a plain JS property (not a Stimulus value) because it is
    // transient per popup session and should not survive connect/disconnect cycles.
    get currentTopicId() {
        if (this.overrideTopicId !== undefined && this.overrideTopicId !== null) {
            return this.overrideTopicId
        }

        const urlParams = new URLSearchParams(window.location.search)
        const urlTopicId = urlParams.get('topic_id')
        if (urlTopicId) return urlTopicId

        return this.serverLastTopicId || ""
    }

    setOverrideTopicId(id) {
        this.overrideTopicId = id ? String(id) : ""
    }

    clearOverrideTopicId() {
        this.overrideTopicId = undefined
    }

    set currentTopicId(id) {
        this.serverLastTopicId = id ? String(id) : ""
        this.debounceSaveLastTopic(id)
    }

    debounceSaveLastTopic(id) {
        if (this._saveLastTopicTimer) clearTimeout(this._saveLastTopicTimer)
        this._saveLastTopicTimer = setTimeout(() => {
            this.flushSaveLastTopic(id)
        }, 500)
    }

    async flushSaveLastTopic(id) {
        if (this._saveLastTopicTimer) {
            clearTimeout(this._saveLastTopicTimer)
            this._saveLastTopicTimer = null
        }
        if (this.creativeId) {
            await saveLastTopic(this.creativeId, id || null)
        }
    }

    migrateLocalStorage() {
        const key = `collavre_creative_${this.creativeId}_last_topic`
        const localValue = localStorage.getItem(key)
        if (localValue && !this.serverLastTopicId) {
            this.serverLastTopicId = localValue
            saveLastTopic(this.creativeId, localValue)
        }
        localStorage.removeItem(key)
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

        if (action === "last_topic_changed") {
            // Broadcast is already scoped to the current user via user-specific channel
            const newTopicId = data.last_topic_id ? String(data.last_topic_id) : ""
            if (newTopicId !== this.serverLastTopicId) {
                this.serverLastTopicId = newTopicId
                this.selectTopic(newTopicId)
            }
            return
        }

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
        const existsById = topics.some((topic) => String(topic.id) === String(data.topic.id))
        if (existsById) return
        // Prevent duplicate topic names (e.g. two "Main" topics from race between
        // HTTP loadTopics and WebSocket broadcast)
        const existsByName = data.topic.name && topics.some((topic) => topic.name === data.topic.name)
        if (existsByName) return

        this.topics = [...topics, data.topic]
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)

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
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
        this.restoreSelection()
    }

    updateTopicInList(updatedTopic) {
        const topics = this.topics || []
        const index = topics.findIndex(t => String(t.id) === String(updatedTopic.id))
        if (index === -1) return

        this.topics[index] = { ...this.topics[index], ...updatedTopic }
        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
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
            this.dispatch("change", { detail: { topicId: "", mainTopicId: this.mainTopicId } })
        }

        this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
        this.restoreSelection()
    }

    handleAddButtonDragOver(event) {
        const isAgent = event.dataTransfer.types.includes('application/x-agent-drop')
        const isComment = event.dataTransfer.types.includes('application/x-comment-ids')
        if (!isAgent && !isComment) return
        event.preventDefault()
        event.dataTransfer.dropEffect = isAgent ? 'copy' : 'move'
        event.currentTarget.classList.add('drag-over')
    }

    async handleAddButtonDrop(event) {
        event.preventDefault()
        event.currentTarget.classList.remove('drag-over')

        // Handle comment drop → create new topic + move
        const commentIdsJson = event.dataTransfer.getData('application/x-comment-ids')
        if (commentIdsJson) {
            const commentIds = JSON.parse(commentIdsJson)
            if (commentIds && commentIds.length > 0) {
                await this.createTopicAndMoveComments(commentIds)
            }
            return
        }

        // Handle agent drop (existing logic)
        const agentJson = event.dataTransfer.getData('application/x-agent-drop')
        if (!agentJson) return

        const agent = JSON.parse(agentJson)
        await this.createTopicWithAgent(agent)
    }

    async createTopicAndMoveComments(commentIds, topicName = null) {
        if (!this.creativeId) return

        const name = topicName || await fetchNextTopicName(this.creativeId)
        if (!name) return

        const result = await createTopicWithComments(this.creativeId, name, commentIds)
        if (result.ok) {
            this.currentTopicId = result.topic.id
            await this.flushSaveLastTopic(result.topic.id)
            await this.loadTopics()
            this.dispatch("change", { detail: { topicId: result.topic.id, mainTopicId: this.mainTopicId } })

            // Clear selection in list controller
            const listController = this.application.getControllerForElementAndIdentifier(
                this.element, 'comments--list'
            )
            if (listController) listController.clearSelection()
        } else {
            alertDialog(result.error)
        }
    }

    // Localized strings are handed down from the ERB partial as data
    // attributes; the English literals are last-resort fallbacks for when the
    // controller is mounted without them.
    _i18n(key) {
        const translations = {
            set_agent_error: this.element.dataset.topicSetAgentError || 'Unable to assign the agent to this topic.',
            agent_assigned_title: this.element.dataset.topicAgentAssignedTitle || '%{name} is assigned to this topic — click to release',
            clear_agent_confirm: this.element.dataset.topicClearAgentConfirm || 'Release %{name} from this topic? Every agent will be able to respond here again.',
            create_error: this.element.dataset.topicCreateError || 'Unable to create the topic.',
            update_error: this.element.dataset.topicUpdateError || 'Unable to update the topic.',
            delete_error: this.element.dataset.topicDeleteError || 'Unable to delete the topic.',
            archive_error: this.element.dataset.topicArchiveError || 'Unable to archive the topic.',
            restore_error: this.element.dataset.topicRestoreError || 'Unable to restore the topic.'
        }
        return translations[key] || key
    }

    // Clicking the avatar of an assigned agent releases the assignment. The avatar
    // sits inside the topic tag, so the click must not also fall through to
    // selecting that topic.
    async clearTopicPrimaryAgent(event) {
        event.preventDefault()
        event.stopPropagation()

        const topicId = event.currentTarget.dataset.id
        if (!topicId) return

        const topic = (this.topics || []).find(t => String(t.id) === String(topicId))
        const agentName = topic?.primary_agent?.name || ''

        const confirmed = await confirmDialog(
            this._i18n('clear_agent_confirm').replace('%{name}', agentName)
        )
        if (!confirmed) return

        await this.setTopicPrimaryAgent(topicId, null)
    }

    // Pass agent === null to release the topic's assignment.
    async setTopicPrimaryAgent(topicId, agent) {
        if (!this.creativeId) return

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics/${topicId}/set_primary_agent`, {
                method: 'PATCH',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                },
                body: JSON.stringify({ agent_id: agent ? agent.id : null })
            })

            const data = await response.json().catch(() => ({}))

            if (!response.ok) {
                alertDialog(data.error || this._i18n("set_agent_error"))
                return
            }

            // Render the avatar from the response rather than waiting for the
            // WebSocket broadcast. A dropped broadcast (e.g. the topics channel
            // subscription was refused) would otherwise leave the avatar
            // invisible until the next page load. The broadcast still runs and
            // propagates the change to other connected users; re-applying it
            // here is a no-op merge.
            if (data.topic) this.updateTopicInList(data.topic)
        } catch (e) {
            console.error('Error setting primary agent', e)
            alertDialog(this._i18n("set_agent_error"))
        }
    }

    async createTopicWithAgent(agent) {
        if (!this.creativeId) return

        const topicName = `Talk to ${agent.name}`

        try {
            const response = await fetch(`/creatives/${this.creativeId}/topics`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                },
                body: JSON.stringify({ topic: { name: topicName }, agent_id: agent.id })
            })

            if (response.ok) {
                const topic = await response.json()
                this.currentTopicId = topic.id
                await this.flushSaveLastTopic(topic.id)
                await this.loadTopics()
                this.dispatch("change", { detail: { topicId: topic.id, mainTopicId: this.mainTopicId } })
            } else {
                // Dropping an agent that has no feedback access here is now
                // refused (it would mute the topic), and that is a user mistake
                // with a fix — sharing the creative. A console line would leave
                // the drop looking like it silently did nothing.
                const data = await response.json().catch(() => ({}))
                const message = data.errors?.[0] || data.error
                console.error('Failed to create topic with agent', message)
                alertDialog(message || this._i18n('create_error'))
            }
        } catch (e) {
            console.error('Error creating topic with agent', e)
            alertDialog(this._i18n('create_error'))
        }
    }

    // When topicId is given the avatar doubles as the release control: clicking it
    // unassigns the agent from the topic. Pass null to render it as a plain badge
    // (viewers who cannot manage topics).
    renderAgentAvatar(agent, topicId = null) {
        const size = 16
        const releasable = topicId !== null && topicId !== undefined
        const title = releasable
            ? this._i18n('agent_assigned_title').replace('%{name}', agent.name)
            : agent.name
        const releaseAttrs = releasable
            ? ` data-action="click->comments--topics#clearTopicPrimaryAgent" data-id="${this.escapeAttr(String(topicId))}" role="button"`
            : ''
        let html = `<span class="avatar-wrapper topic-agent-avatar-wrapper${releasable ? ' topic-agent-avatar-releasable' : ''}"${releaseAttrs} style="width:${size}px;height:${size}px;" title="${this.escapeAttr(title)}">`
        html += `<img src="${this.escapeAttr(agent.avatar_url)}" alt="" width="${size}" height="${size}" class="topic-agent-avatar" style="border-radius:50%;vertical-align:middle;">`
        if (agent.default_avatar) {
            html += `<span class="avatar-initial">${this.escapeAttr(agent.initial)}</span>`
        }
        html += `</span>`
        return html
    }

    escapeAttr(str) {
        if (!str) return ''
        return str.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    }
}
