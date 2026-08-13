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
        const previousCreativeId = this.creativeIdValue
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
        // among its topics. Only on an actual switch, though: a docked chat
        // re-opens the *same* creative when a workspace-sync event carries a
        // highlightId (popup_controller.handleCreativeClick), and these marks are
        // transient — loadTopics() cannot rebuild them.
        if (String(previousCreativeId || '') !== String(creativeId || '')) {
            this.archivedWithNewMessages.clear()
            // Scoped to the creative it was archived in; a topic id from another
            // creative must not veto this one's restored selection.
            this.archivedAwayTopicId = null
        }
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
        this.archivedAwayTopicId = null
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

    // list_controller asks this before appending a live message to All Messages:
    // CommentsController#index leaves archived-topic comments out of that view,
    // so a stream must not put one there either.
    isArchivedTopic(id) {
        if (!id) return false
        return (this.archivedTopics || []).some(t => String(t.id) === String(id))
    }

    // Move a topic between the live and archived caches without waiting for the
    // reload. Every caller follows with loadTopics(), which clears this.topics
    // synchronously and refills both lists when its fetch lands — so this only
    // has to be right for the window in between, which is exactly the window
    // isArchivedTopic is consulted in.
    applyArchiveTransition(action, topic) {
        const id = topic && topic.id
        if (!id) return

        const key = String(id)
        const known = [ ...(this.topics || []), ...(this.archivedTopics || []) ]
            .find(t => String(t.id) === key)
        const entry = { ...(known || {}), ...topic }

        this.topics = (this.topics || []).filter(t => String(t.id) !== key)
        this.archivedTopics = (this.archivedTopics || []).filter(t => String(t.id) !== key)

        if (action === "archived") {
            this.archivedTopics = [ ...this.archivedTopics, entry ]
        } else {
            this.topics = [ ...this.topics, entry ]
            // Nothing archived is left to clear the badge from, so drop it here
            // rather than leaving the toggle lit until the reload lands.
            this.pruneArchivedBadges()
        }
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
        const selectionEpoch = this.selectionEpoch
        const creativeId = this.creativeId
        // Clear stale topics from previous creative to prevent name-based
        // dedupe in handleTopicMessage from blocking valid broadcasts
        this.topics = []

        try {
            const response = await fetch(`/creatives/${creativeId}/topics`)
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
                // A topic picked while this fetch was in flight is newer intent
                // than the answer coming back: last_topic_id still names the
                // topic the user left, because the save for the pick is
                // debounced and has not landed. Overwriting it here — and then
                // restoring from it below — throws the click away, snapping the
                // strip and the message list back to the previous topic.
                // _loadTopicsVersion does not cover this: it only discards a
                // response outrun by another loadTopics(), not by a selection.
                //
                // Only a pick about this creative, though. Switching creatives
                // leaves the previous creative's chips on screen until this
                // fetch lands, and a click on one of those is intent about the
                // creative being left. Its id would survive as the preference,
                // fail the lookup in restoreSelection(), drop the user on Main
                // and then persist Main as the new creative's saved topic.
                const pickWon = this.pickOutranks(selectionEpoch, creativeId, topics, this.archivedTopics)
                if (!pickWon) {
                    this.serverLastTopicId = data.last_topic_id ? String(data.last_topic_id) : ""
                }
                // The archive guard only has to outlive the sources that still
                // name the topic. Test the effective selection, not just the
                // preference: an unchanged ?topic_id= outranks it in the getter,
                // so keying on serverLastTopicId would drop the guard while the
                // URL was still pointing at the archived topic. Once nothing
                // names it, a later reselection is honoured normally.
                if (this.archivedAwayTopicId && String(this.currentTopicId) !== this.archivedAwayTopicId) {
                    this.archivedAwayTopicId = null
                }
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
                this.migrateLocalStorage({ keepEmptyPick: pickWon })

                this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent)
                this.restoreSelection({ keepEmptyPick: pickWon })
            }
        } catch (e) {
            console.error("Failed to load topics", e)
            throw e
        }
    }

    // keepEmptyPick: the caller established that the user picked All Messages
    // after this render was set in motion. That pick names no topic, so it
    // cannot be restored — it can only be left alone. Without this the Main
    // fallback below would treat it as "nothing selected", navigate away from
    // it and persist Main, which is the same revert a chip click suffers.
    restoreSelection({ keepEmptyPick = false } = {}) {
        const lastTopicId = this.currentTopicId
        // archiveTopic() switched away from this topic on purpose. The server
        // preference still names it until the debounced save lands, so accept
        // the local intent over the stale server answer for that window.
        if (lastTopicId && String(lastTopicId) !== this.archivedAwayTopicId) {
            // Validate against the topic data, not the rendered DOM. An archived
            // topic is still readable and writable — archiving hides it from the
            // strip, it does not close the conversation. A DOM lookup would bounce
            // the user back to Main every time the archived section is collapsed,
            // because collapsed chips are never rendered. selectTopic expands the
            // section when the selection lands inside it.
            const known = [ ...(this.topics || []), ...(this.archivedTopics || []) ]
            if (known.some(t => String(t.id) === String(lastTopicId))) {
                // Restoring is not a navigation, so it must not undo a collapse
                // the user chose while sitting in this very topic. Only
                // restoreSelection is suppressed; every other selectTopic caller
                // is the user going somewhere, and reveals normally.
                const reveal = this.archivedCollapsedTopicId !== String(lastTopicId)
                this.selectTopic(lastTopicId, { reveal, pick: false })
                return
            }
        }

        if (keepEmptyPick && !lastTopicId) return

        // Not a pick: this fallback is what the current state resolves to, and
        // loadTopics() empties the strip for the length of its fetch, so any
        // re-render landing in that window resolves to Main whatever the user
        // has selected. Counting it as intent would let it outrank the answer
        // it was derived from — and drop the deep link on the way.
        this.selectTopic(this.mainTopicId || "", { pick: false })
    }

    // An archived topic can be opened from the topic strip, the topic-list popup,
    // a deep link, or a restored last-topic. Expand the archived section from this
    // one choke point so the strip always shows which topic is open.
    revealArchivedTopic(id) {
        if (!id || this.showingArchived) return
        if (!this.isArchivedTopic(id)) return

        // Reaching here is a deliberate navigation into the section, so an
        // earlier collapse no longer describes what the user wants.
        this.archivedCollapsedTopicId = null
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
            const unreadBadge = topic.unread_count > 0
                ? `<span class="topic-unread-badge">${topic.unread_count}</span>`
                : ''
            const isMainTopic = this.mainTopicId && String(topic.id) === String(this.mainTopicId)
            let s = `<span class="topic-tag topic-drop-target ${isActive}" ${draggable}
                          data-action="click->comments--topics#select ${dropActions} ${dragActions} ${topicDropActions}"
                          data-id="${topic.id}"${topic.source_topic_id ? ` data-source-topic-id="${topic.source_topic_id}"` : ''}>
                        ${agentAvatar}${branchIcon}#${topic.name}${unreadBadge}`
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
                    const unreadBadge = topic.unread_count > 0
                        ? `<span class="topic-unread-badge">${topic.unread_count}</span>`
                        : ''
                    html += `<span class="topic-tag topic-archived${isActive}${hasNew}"
                                   data-action="click->comments--topics#select"
                                   data-id="${topic.id}">
                              #${topic.name}${unreadBadge}
                              ${canManage ? `<button class="unarchive-topic-btn" data-action="click->comments--topics#unarchiveTopic" data-id="${topic.id}" title="Restore">${ICON_RESTORE}</button>` : ''}
                             </span>`
                })
            }
        }

        this.listTarget.innerHTML = html
        // Which creative the chips now on screen belong to. A click can only
        // ever be about this one, whatever this.creativeId has since become.
        this._renderedCreativeId = this.creativeId

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
                    // Same deep-link hazard as the "deleted" broadcast: this
                    // path reaches restoreSelection through loadTopics instead
                    // of removeTopic, but the getter is the same one.
                    this.releaseDeepLinkSelection(topicId)
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
                    // Archiving the topic in view switches to All Messages, but
                    // the preference save is debounced 500ms and both this
                    // reload and the "archived" broadcast's own reload can beat
                    // it. restoreSelection() accepts archived ids now, so the
                    // stale last_topic_id would drop the user straight back into
                    // the topic they just archived out of. Flag it instead of
                    // flushing the save: the broadcast reload cannot be ordered
                    // behind the flush, only ignored.
                    this.archivedAwayTopicId = String(topicId)
                    // Both sources that outrank serverLastTopicId in the
                    // currentTopicId getter have to go too, or the archived
                    // topic stays the effective selection no matter what the
                    // preference says: overrideTopicId (deep link) and the
                    // ?topic_id= query parameter.
                    this.releaseDeepLinkSelection(topicId)
                    this.currentTopicId = ""
                    this.dispatch("change", { detail: { topicId: "", mainTopicId: this.mainTopicId } })
                }
                // The actor has the same stale-membership window as everyone
                // receiving the broadcast, so close it on this side too.
                this.applyArchiveTransition("archived", { id: topicId })
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
                this.applyArchiveTransition("unarchived", { id: topicId })
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
        // Collapsing while the open topic lives in this section is a deliberate
        // choice to hide it, so record it. Every re-render runs restoreSelection
        // → selectTopic → revealArchivedTopic, which would otherwise reopen the
        // section on any unrelated rename, reorder, or topic broadcast.
        this.archivedCollapsedTopicId = !this.showingArchived && this.isArchivedTopic(this.currentTopicId)
            ? String(this.currentTopicId)
            : null
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

    selectTopic(id, { reveal = true, pick = true } = {}) {
        // Only restoreSelection() is guarded, so reaching selectTopic with this
        // id means the user deliberately went back into the archived topic.
        // The transition is over.
        if (this.archivedAwayTopicId && String(id) === this.archivedAwayTopicId) {
            this.archivedAwayTopicId = null
        }
        if (reveal) this.revealArchivedTopic(id)
        this.updateSelectionUI(id, { pick })
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

    updateSelectionUI(id, { pick = true } = {}) {
        this.applySelection(id, { pick })
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

        const isArchived = this.isArchivedTopic(topicId)
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

    // Is one of the two sources above the preference still set? Not the same
    // question as "is the getter's answer nonempty" — an override of "" outranks
    // the preference just as a named one does.
    get hasDeepLinkSelection() {
        if (this.overrideTopicId !== undefined && this.overrideTopicId !== null) return true

        return Boolean(new URLSearchParams(window.location.search).get('topic_id'))
    }

    // A topic leaving the strip — archived or deleted — has to leave both
    // sources that outrank serverLastTopicId in the currentTopicId getter.
    // Assigning "" only touches the preference, so on its own the getter goes
    // on naming the gone topic and every later restoreSelection() finds it
    // unknown and resets to Main, discarding whatever the user picked instead.
    releaseDeepLinkSelection(topicId) {
        this.clearOverrideTopicId()
        this.clearUrlTopicId(topicId)
    }

    // Drop ?topic_id= when it names the topic being archived. It is a selection
    // source in its own right and survives every reload, so leaving it would
    // re-select the topic the user just archived out of. replaceState, not a
    // navigation: the chat state around it must stay put.
    clearUrlTopicId(topicId) {
        const url = new URL(window.location.href)
        if (url.searchParams.get('topic_id') !== String(topicId)) return

        url.searchParams.delete('topic_id')
        window.history.replaceState(window.history.state, '', url.toString())
    }

    setOverrideTopicId(id) {
        this.overrideTopicId = id ? String(id) : ""
    }

    clearOverrideTopicId() {
        this.overrideTopicId = undefined
    }

    set currentTopicId(id) {
        this.applySelection(id)
    }

    // pick: this selection is new intent — the user picked it, or the server
    // told us their preference moved. A restore is not: it re-derives the
    // selection from state already held, so it is never newer than anything and
    // must leave the sources that outrank the preference alone. Recording the
    // preference and saving it happen either way; only the two consequences of
    // *intent* are gated.
    applySelection(id, { pick = true } = {}) {
        this.serverLastTopicId = id ? String(id) : ""
        if (pick) {
            // Writing only the preference leaves the two sources that outrank it
            // in the getter still naming the topic being left, so the getter
            // keeps answering with it: the next renderTopics() lights the old
            // chip and the next restoreSelection() navigates back to it. Both
            // are one-shot pointers at a topic to open, and this selection has
            // moved off it. Dropped only when they disagree — a deep link that
            // resolved to the topic now being selected must keep outranking the
            // stale server last_topic_id for the rest of the popup session.
            this.releaseSelectionSourcesOtherThan(this.serverLastTopicId)
            this.selectionEpoch += 1
            this._pickCreativeId = this._renderedCreativeId
        }
        this.debounceSaveLastTopic(id)
    }

    // Bumped on every selection so an in-flight loadTopics() can tell whether
    // its answer predates a pick the user has since made.
    get selectionEpoch() {
        return this._selectionEpoch || 0
    }

    set selectionEpoch(value) {
        this._selectionEpoch = value
    }

    // Did a pick land after the load at `epoch` started, and is it a pick about
    // the creative that load describes? The first half says the pick is newer
    // than the answer; the second is decided by the strip the click landed on,
    // not by this.creativeId — onPopupOpened assigns that synchronously before
    // the fetch, so a click on the outgoing creative's chips already carries the
    // incoming id. The rendered strip is what the user was actually looking at.
    //
    // An empty pick (All Messages) names no topic to match against the response,
    // and its provenance is the only thing that distinguishes it from a click on
    // a stale strip — so it rests on that test alone. A named pick is checked
    // against the topics too: one whose topic the response does not list was
    // made against a strip that predates a delete, and keeping it would fail the
    // lookup in restoreSelection() and persist Main in its place.
    pickOutranks(epoch, creativeId, topics, archivedTopics) {
        if (this.selectionEpoch === epoch) return false
        // creativeId is always truthy here — loadTopics() returns without it —
        // so a pick made before any strip was rendered fails this too.
        if (String(this._pickCreativeId) !== String(creativeId)) return false
        if (!this.serverLastTopicId) return true

        return [ ...(topics || []), ...(archivedTopics || []) ]
            .some(t => String(t.id) === String(this.serverLastTopicId))
    }

    releaseSelectionSourcesOtherThan(id) {
        if (this.overrideTopicId !== undefined && this.overrideTopicId !== null &&
            String(this.overrideTopicId) !== String(id)) {
            this.clearOverrideTopicId()
        }

        const urlTopicId = new URLSearchParams(window.location.search).get('topic_id')
        if (urlTopicId && urlTopicId !== String(id)) {
            this.clearUrlTopicId(urlTopicId)
        }
    }

    debounceSaveLastTopic(id) {
        this.cancelPendingSaveLastTopic()
        this._saveLastTopicTimer = setTimeout(() => {
            this.flushSaveLastTopic(id)
        }, 500)
    }

    // Drop a queued save without sending it. The timer closes over the id it
    // was scheduled with, so a save that is no longer wanted cannot be talked
    // out of its value — only cancelled.
    cancelPendingSaveLastTopic() {
        if (this._saveLastTopicTimer) {
            clearTimeout(this._saveLastTopicTimer)
            this._saveLastTopicTimer = null
        }
    }

    async flushSaveLastTopic(id) {
        this.cancelPendingSaveLastTopic()
        if (this.creativeId) {
            await saveLastTopic(this.creativeId, id || null)
        }
    }

    // The legacy key is adopted only as a stand-in for a preference the server
    // does not hold yet. A winning empty pick is a preference — it just names no
    // topic, so it is indistinguishable here from "server holds nothing", and
    // adopting the legacy value would hand the user back a topic they did not
    // ask for and persist it. The caller knows which of the two it is.
    //
    // The key still goes, either way: the pick supersedes it, and its own save
    // is already on the way, so leaving it behind would only re-apply a value
    // the user has moved off on the next load.
    migrateLocalStorage({ keepEmptyPick = false } = {}) {
        const key = `collavre_creative_${this.creativeId}_last_topic`
        const localValue = localStorage.getItem(key)
        if (localValue && !this.serverLastTopicId && !keepEmptyPick) {
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
                // Another session moved the preference; nobody clicked in this
                // popup. A deep link outranks the preference in the getter, so
                // following the broadcast would light a chip the getter does not
                // name — and selectTopic() writes through the setter, which
                // releases that link on the way. It is a one-shot pointer with
                // nowhere to be recovered from: ?topic_id= is dropped from the
                // URL, so not even a reload gets the linked conversation back.
                // Record the preference, leave the view where the link put it.
                //
                // Every selection queues a save, restores included, so landing
                // on the link 500ms ago left one holding the linked topic. It
                // describes a selection this popup has just conceded is not the
                // preference; letting it land would write the link back over
                // what the other session set. Following the broadcast re-arms
                // the debounce with the broadcast's own value, so only the path
                // that does not follow has anything to cancel.
                if (this.hasDeepLinkSelection) {
                    this.cancelPendingSaveLastTopic()
                } else {
                    this.selectTopic(newTopicId)
                }
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
            // loadTopics() only refreshes archivedTopics when its fetch resolves,
            // and list_controller routes every incoming stream through
            // isArchivedTopic in the meantime. The broadcast already carries the
            // membership change, so apply it now rather than letting that window
            // route on the old answer.
            this.applyArchiveTransition(action, data.topic || { id: data.topic_id })
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
        const archivedTopics = this.archivedTopics || []
        const nextTopics = topics.filter((topic) => String(topic.id) !== String(topicId))
        // An archived topic is deletable and now selectable, so the "deleted"
        // broadcast has to reach this cache too — nothing else does. It is the
        // only removal path that runs without a loadTopics(), so a topic dropped
        // from here would keep an openable chip and, through pruneArchivedBadges
        // never running, a lit toggle for a conversation that no longer exists.
        const nextArchivedTopics = archivedTopics.filter((topic) => String(topic.id) !== String(topicId))
        if (nextTopics.length === topics.length && nextArchivedTopics.length === archivedTopics.length) return

        this.topics = nextTopics
        this.archivedTopics = nextArchivedTopics
        this.pruneArchivedBadges()
        if (String(this.currentTopicId) === String(topicId)) {
            this.releaseDeepLinkSelection(topicId)
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
