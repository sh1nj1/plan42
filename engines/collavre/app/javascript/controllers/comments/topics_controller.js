import { Controller } from "@hotwired/stimulus"
import { createSubscription } from "../../services/cable"
import { fetchNextTopicName, createTopicWithComments, saveLastTopic } from "../../lib/api/topics"
import { alertDialog, confirmDialog } from "../../lib/utils/dialog"

const ICON_ARCHIVE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg>`
const ICON_RESTORE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6.69 3L3 13"/></svg>`
const AMBIGUOUS_SAVE_CLAIM_TIMEOUT = 5_000
const SAVE_REQUEST_TIMEOUT = 5_000
const UNREAD_COUNT_REFRESH_DELAY = 250
const TOPIC_SCROLL_DURATION = 250
const LAST_TOPIC_SAVE_SESSION_STORAGE_KEY = "collavre:last-topic-save-session-id"
const LAST_TOPIC_SAVE_SEQUENCE_STORAGE_KEY = "collavre:last-topic-save-sequence"
const LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX = "collavre:last-topic-save-session:"
let fallbackClientIdSequence = 0

// Names one save, so its broadcast can be told from a sibling session's. It
// has to be unique across the user's tabs, not just within this one: two tabs
// counting from zero would answer to each other's echoes.
function newClientId() {
    if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()

    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
        const bytes = crypto.getRandomValues(new Uint8Array(16))
        return `save-${Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')}`
    }

    fallbackClientIdSequence += 1
    return `save-${Date.now().toString(36)}-${fallbackClientIdSequence.toString(36)}`
}

export default class extends Controller {
    static targets = ["list", "creationContainer", "topicListButton"]

    connect() {
        this.topics = []
        this.canManageTopics = false
        this.canCreateTopic = false
        this.canSetPrimaryAgent = false
        this.subscribedCreativeId = null
        this.topicsSubscription = null
        this._loadTopicsVersion ||= 0
        this._unreadCountsOverlay = null
        this._topicScrollFrame = null
        // Initial load if creativeId is available (e.g. from dataset if set server-side)
        if (this.creativeId && this.element.dataset.docked !== 'true') {
            this.loadTopics()
            this.subscribe()
        }
        this.handleNewMessage = this.handleNewMessage.bind(this)
        this.handleTopicMoved = this.handleTopicMoved.bind(this)
        this.handleTopicListClose = this.handleTopicListClose.bind(this)
        this.cancelProgrammaticScroll = this.cancelProgrammaticScroll.bind(this)
        window.addEventListener('comments--topics:new-message', this.handleNewMessage)
        window.addEventListener('collavre:topic-moved', this.handleTopicMoved)
        this.element.addEventListener('topic-list:close', this.handleTopicListClose)
        this.listTarget.addEventListener('wheel', this.cancelProgrammaticScroll, { passive: true })
        this.listTarget.addEventListener('touchstart', this.cancelProgrammaticScroll, { passive: true })
    }

    disconnect() {
        this.cancelProgrammaticScroll()
        window.removeEventListener('comments--topics:new-message', this.handleNewMessage)
        window.removeEventListener('collavre:topic-moved', this.handleTopicMoved)
        this.element.removeEventListener('topic-list:close', this.handleTopicListClose)
        this.listTarget.removeEventListener('wheel', this.cancelProgrammaticScroll)
        this.listTarget.removeEventListener('touchstart', this.cancelProgrammaticScroll)
        this._loadTopicsVersion += 1
        this.cancelUnreadCountRefresh()
        this.unsubscribe()
    }

    onPopupOpened({ creativeId }) {
        this._popupClosed = false
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
        // Do not prune retained claims until loadTopics() has resolved this
        // requested creative to its effective stream id. A linked shell and
        // its origin use the same TopicsChannel stream, but only the response
        // tells us that after this cached value has been cleared.
        // Direct history navigation replaces the subscription without firing
        // onPopupClosed(). Keep claims until loadTopics() can resolve whether
        // this requested creative shares the previous effective stream.
        this.subscribe({ preservePendingSelfEchoes: true })
        return this.loadTopics()
    }

    onPopupClosed() {
        this._popupClosed = true
        this.releaseAcknowledgedPendingSelfEchoes()
        this.markPendingSelfEchoesAsPossiblyMissed()
        this._loadTopicsVersion += 1
        this.cancelUnreadCountRefresh()
        // The same creative can reopen before an in-flight save broadcasts.
        // Keep that save's claim so its delayed echo remains recognisable on
        // the replacement subscription; a different creative clears it when
        // it opens.
        this.unsubscribe({ preservePendingSelfEchoes: true })
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

    // TopicsChannel and update_last_topic both resolve linked shells through
    // effective_origin. Before a response provides that id, the requested id
    // is the best available stream key. A shell that has already loaded keeps
    // its resolved stream across a close/reopen, so an acknowledgement arriving
    // before the replacement load can still tell that its echo is receivable.
    get effectiveCreativeId() {
        return this.element.dataset.effectiveCreativeId || this.effectiveCreativeIdFor(this.creativeId)
    }

    // A pending pick records the shell rendered in the popup, while channel
    // claims are keyed by the origin stream. Resolve both through the cached
    // mapping before comparing them so a linked-shell replacement keeps a newer
    // pick ahead of an orphaned echo from the previous controller.
    effectiveCreativeIdFor(creativeId) {
        return this.knownEffectiveCreativeIds.get(String(creativeId)) || creativeId
    }

    async loadTopics() {
        if (!this.creativeId) return

        const version = ++this._loadTopicsVersion
        this._unreadCountsOverlay = null
        const selectionEpoch = this.selectionEpoch
        // A response can carry a snapshot produced before a save, while that
        // save's HTTP response reaches us before the snapshot is processed.
        // Remember which local saves had been acknowledged when this load
        // started so their retained claims can still outrank that older view.
        const acknowledgedSaveVersion = this.saveAcknowledgementVersion
        this.activeLoadAcknowledgementVersions.set(version, acknowledgedSaveVersion)
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
                const unreadCounts = this._unreadCountsOverlay?.loadVersion === version
                    ? this._unreadCountsOverlay.counts
                    : null
                const topics = this.applyUnreadCounts(Array.isArray(data) ? data : data.topics, unreadCounts)
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
                this.archivedTopics = this.applyUnreadCounts(data.archived_topics || [], unreadCounts)
                this.pruneArchivedBadges()
                const effectiveCreativeId = data.effective_creative_id
                    ? String(data.effective_creative_id)
                    : String(this.creativeId)
                this.knownEffectiveCreativeIds.set(String(creativeId), effectiveCreativeId)
                const snapshotTopicId = data.last_topic_id ? String(data.last_topic_id) : ""
                const snapshotTopicRevision = this.normalizeLastTopicRevision(data.last_topic_revision)
                this.element.dataset.effectiveCreativeId = effectiveCreativeId
                this.remapPendingSelfEchoesForCreative(creativeId, effectiveCreativeId)
                this.releaseAcknowledgedPendingSelfEchoesOutside(effectiveCreativeId)
                const staleLastTopicSnapshot = !this.observeLastTopicRevision(
                    effectiveCreativeId,
                    snapshotTopicRevision
                )
                const deferLastTopicReconciliation = this.hasUnacknowledgedRevisionedSaveFor(
                    effectiveCreativeId,
                    snapshotTopicRevision
                )
                if (deferLastTopicReconciliation) {
                    this.deferredLastTopicReconciliations.add(effectiveCreativeId)
                }
                // Claims are keyed by their effective creative stream. Keep claims
                // for a stream we have temporarily left: a save can still be in
                // flight while the popup visits another creative, and returning before
                // its echo arrives must still recognise that echo as our own.
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
                const skipLastTopicReconciliation = staleLastTopicSnapshot || deferLastTopicReconciliation
                const pickWon = !skipLastTopicReconciliation && !this.pendingPickWasSupersededWhileClosed(
                    effectiveCreativeId,
                    snapshotTopicId,
                    snapshotTopicRevision
                ) && this.pickOutranks(selectionEpoch, creativeId, topics, this.archivedTopics)
                if (skipLastTopicReconciliation) {
                    // The GET has a server ordering token, but this save has neither
                    // its response revision nor its echo yet. Its predecessor topic is
                    // not an ordering token (an ABA write can repeat it), so preserve
                    // the current selection until the request settles and retry below.
                    // A snapshot older than an already observed revision is likewise
                    // display data only; it must not restore an older preference.
                } else if (pickWon) {
                    // An interim restore can run while this fetch has the strip
                    // empty and replace serverLastTopicId with Main. The epoch
                    // belongs to the actual pick, so restore that picked value
                    // rather than treating the derived fallback as its value.
                    this.serverLastTopicId = this._pickTopicId
                    // The picked value has not necessarily reached the server yet.
                    // Keep the snapshot as the first known remote baseline so a
                    // claim created after this load records what its pending save
                    // actually supersedes. Never replace a newer Action Cable or
                    // acknowledged-save baseline with this older response.
                    if (this.lastKnownRemoteTopicIdFor(effectiveCreativeId) === undefined) {
                        this.setLastKnownRemoteTopicId(effectiveCreativeId, snapshotTopicId)
                    }
                } else {
                    const pendingTopicId = this.latestPendingSelfEchoTopicIdFor(
                        effectiveCreativeId,
                        snapshotTopicId,
                        acknowledgedSaveVersion,
                        snapshotTopicRevision
                    )
                    if (pendingTopicId === undefined) {
                        this.serverLastTopicId = snapshotTopicId
                        // A retained claim proves this response was an older view of
                        // the preference. Do not let that stale snapshot roll back
                        // the baseline used by the next save's closed-reopen check.
                        this.setLastKnownRemoteTopicId(effectiveCreativeId, snapshotTopicId)
                    } else {
                        this.serverLastTopicId = pendingTopicId
                    }
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
                // Migrate localStorage to server if server has no value. An
                // unresolved revisioned save must not turn its retained local
                // selection into another PATCH while reconciliation is deferred.
                if (!skipLastTopicReconciliation) {
                    this.migrateLocalStorage({ keepEmptyPick: pickWon })
                }

                this.renderTopics(this.topics, this.canManageTopics, this.canCreateTopic, this.canSetPrimaryAgent, creativeId)
                if (this.currentTopicId) this.clearNewMessageBadge(this.currentTopicId)
                if (!skipLastTopicReconciliation) {
                    this.restoreSelection({ keepEmptyPick: pickWon })
                }
                this.refreshOpenTopicListPopup()
            }
        } catch (e) {
            console.error("Failed to load topics", e)
            throw e
        } finally {
            this.activeLoadAcknowledgementVersions.delete(version)
            this.discardSettledSelfEchoesNoLongerNeeded()
        }
    }

    // keepEmptyPick: the caller established that the user picked All Messages
    // after this render was set in motion. That pick names no topic, so it
    // cannot be restored from a topic list — it must be reapplied. Without
    // this the Main fallback below would treat it as "nothing selected",
    // navigate away from it and persist Main, which is the same revert a chip
    // click suffers. A prior interim restore may also have dispatched Main, so
    // reapplying sends the authoritative empty selection to downstream
    // controllers again.
    restoreSelection({ keepEmptyPick = false } = {}) {
        const lastTopicId = this.currentTopicId
        // A deep link controls this popup's view, but it is not a replacement
        // for the saved preference. Replaying the linked selection after a
        // preference broadcast must therefore update the UI without writing the
        // link back over that newer server value.
        const preservePreference = this.hasDeepLinkSelection && !keepEmptyPick
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
                this.selectTopic(lastTopicId, { reveal, pick: false, persist: !preservePreference })
                return
            }
        }

        if (keepEmptyPick && !lastTopicId) {
            this.selectTopic("", { pick: false })
            return
        }

        if (preservePreference && !lastTopicId) {
            this.selectTopic("", { pick: false, persist: false })
            return
        }

        // Not a pick: this fallback is what the current state resolves to, and
        // loadTopics() empties the strip for the length of its fetch, so any
        // re-render landing in that window resolves to Main whatever the user
        // has selected. Counting it as intent would let it outrank the answer
        // it was derived from — and drop the deep link on the way.
        this.selectTopic(this.mainTopicId || "", { pick: false, persist: !preservePreference })
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

    renderTopics(topics, canManage = false, canCreateTopic = canManage, canSetPrimaryAgent = canManage, sourceCreativeId = this._topicsCreativeId || this.creativeId) {
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
        this._renderedCreativeId = sourceCreativeId
        this._topicsCreativeId = sourceCreativeId

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
        if (this.topicListTogglePointerDown) {
            this.cancelTopicListToggle()
            return
        }

        const btnRect = event.currentTarget.getBoundingClientRect()

        const openWith = (popup) => {
            popup.openForTopics(
                this.topicListData(),
                btnRect,
                (item) => this.selectTopic(item.id),
                this.element
            )
            this.setTopicListButtonExpanded(true)
        }

        let modal = document.getElementById('topic-list-modal')
        if (modal) {
            const popup = this.application.getControllerForElementAndIdentifier(modal, 'topic-list')
            if (popup?.popup?.isOpen()) {
                popup?.close()
                this.setTopicListButtonExpanded(false)
            } else if (popup) {
                openWith(popup)
            }
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

    topicListData() {
        return {
            topics: this.topics || [],
            archivedTopics: this.archivedTopics || [],
            mainTopicId: this.mainTopicId,
            allMessagesLabel: this.element.dataset.topicMainText || 'All Messages'
        }
    }

    refreshOpenTopicListPopup() {
        const modal = this.element.querySelector('#topic-list-modal')
        const popup = modal && this.application.getControllerForElementAndIdentifier(modal, 'topic-list')
        if (popup?.popup?.isOpen()) popup.updateTopics(this.topicListData())
    }

    scheduleUnreadCountRefresh() {
        if (this._unreadCountRefreshInFlight) {
            this._unreadCountRefreshQueued = true
            return
        }
        if (this._unreadCountRefreshTimer) return

        this._unreadCountRefreshTimer = setTimeout(() => {
            this._unreadCountRefreshTimer = null
            this._unreadCountRefreshInFlight = true
            this.refreshUnreadCounts()
                .catch(error => console.error("Failed to refresh topic unread counts", error))
                .finally(() => {
                    this._unreadCountRefreshInFlight = false
                    if (!this._unreadCountRefreshQueued) return

                    this._unreadCountRefreshQueued = false
                    this.scheduleUnreadCountRefresh()
                })
        }, UNREAD_COUNT_REFRESH_DELAY)
    }

    cancelUnreadCountRefresh() {
        clearTimeout(this._unreadCountRefreshTimer)
        this._unreadCountRefreshTimer = null
        this._unreadCountRefreshQueued = false
    }

    async refreshUnreadCounts() {
        if (!this.creativeId) return

        const creativeId = String(this.creativeId)
        const loadVersion = this._loadTopicsVersion
        const response = await fetch(`/creatives/${creativeId}/topics`)
        if (!response.ok) return

        const data = await response.json()
        if (String(this.creativeId) !== creativeId || this._loadTopicsVersion !== loadVersion) return

        const activeTopics = Array.isArray(data) ? data : data.topics
        const counts = new Map(
            [...(activeTopics || []), ...(data.archived_topics || [])]
                .map(topic => [String(topic.id), Number(topic.unread_count) || 0])
        )
        this._unreadCountsOverlay = { loadVersion, counts }
        this.topics = this.applyUnreadCounts(this.topics, counts)
        this.archivedTopics = this.applyUnreadCounts(this.archivedTopics, counts)
        if (this.currentTopicId) this.clearNewMessageBadge(this.currentTopicId)
        this.refreshRenderedUnreadCounts()
        this.refreshOpenTopicListPopup()
    }

    applyUnreadCounts(topics = [], counts = null) {
        if (!counts) return topics

        return topics.map(topic => counts.has(String(topic.id))
            ? { ...topic, unread_count: counts.get(String(topic.id)) }
            : topic)
    }

    refreshRenderedUnreadCounts() {
        const topicsById = new Map(
            [...(this.topics || []), ...(this.archivedTopics || [])]
                .map(topic => [String(topic.id), topic])
        )

        this.listTarget.querySelectorAll('.topic-tag[data-id]').forEach(topicEl => {
            const topic = topicsById.get(String(topicEl.dataset.id))
            if (!topic || topicEl.querySelector('.topic-edit-input')) return

            const count = Number(topic.unread_count) || 0
            const badge = topicEl.querySelector('.topic-unread-badge')
            if (count <= 0) {
                badge?.remove()
                return
            }
            if (badge) {
                badge.textContent = String(count)
                return
            }

            const newBadge = document.createElement('span')
            newBadge.className = 'topic-unread-badge'
            newBadge.textContent = String(count)
            topicEl.insertBefore(newBadge, topicEl.querySelector('button'))
        })
    }

    prepareTopicListToggle(event) {
        if (event.isPrimary === false || event.button !== 0) return

        const modal = document.getElementById('topic-list-modal')
        const popup = modal && this.application.getControllerForElementAndIdentifier(modal, 'topic-list')
        // Let every open popup receive this pointer event and perform its normal
        // outside-click cleanup. If this popup was one of them, consume the
        // following click so it does not immediately reopen.
        if (popup?.popup?.isOpen()) {
            this.topicListTogglePointerDown = true
            this.topicListTogglePointerId = event.pointerId
            event.currentTarget.setPointerCapture(event.pointerId)
        }
    }

    finishTopicListToggle(event) {
        if (event.pointerId !== this.topicListTogglePointerId) return

        const rect = event.currentTarget.getBoundingClientRect()
        const releasedOutsideButton = event.clientX < rect.left || event.clientX > rect.right ||
            event.clientY < rect.top || event.clientY > rect.bottom
        if (releasedOutsideButton) {
            this.cancelTopicListToggle(event)
        } else {
            // A completed activation dispatches click before the next task. Clear a
            // canceled in-button gesture afterwards so it cannot consume a later click.
            this.topicListToggleClearTimeout = setTimeout(() => this.cancelTopicListToggle(event), 0)
        }
    }

    cancelTopicListToggle(event = {}) {
        if (event.pointerId != null && event.pointerId !== this.topicListTogglePointerId) return

        clearTimeout(this.topicListToggleClearTimeout)
        this.topicListToggleClearTimeout = undefined
        this.topicListTogglePointerDown = false
        this.topicListTogglePointerId = undefined
    }

    handleTopicListClose() {
        this.setTopicListButtonExpanded(false)
    }

    setTopicListButtonExpanded(expanded) {
        if (this.hasTopicListButtonTarget) {
            this.topicListButtonTarget.setAttribute('aria-expanded', String(expanded))
        }
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

    selectTopic(id, { reveal = true, pick = true, persist = true } = {}) {
        // Only restoreSelection() is guarded, so reaching selectTopic with this
        // id means the user deliberately went back into the archived topic.
        // The transition is over.
        if (this.archivedAwayTopicId && String(id) === this.archivedAwayTopicId) {
            this.archivedAwayTopicId = null
        }
        if (reveal) this.revealArchivedTopic(id)
        this.updateSelectionUI(id, { pick, persist, pending: pick })
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
            this.refreshRenderedUnreadCounts()
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

    updateSelectionUI(id, { pick = true, persist = true, pending = false } = {}) {
        this.applySelection(id, { pick, persist, pending })
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
        if (activeEl) this.scrollTopicIntoView(activeEl)
    }

    scrollToActiveTopic() {
        const activeEl = this.listTarget.querySelector('.topic-tag.active')
        if (activeEl) this.scrollTopicIntoView(activeEl)
    }

    scrollTopicIntoView(topic) {
        this.cancelProgrammaticScroll()
        const list = this.listTarget
        const listRect = list.getBoundingClientRect()
        const topicRect = topic.getBoundingClientRect()
        const maxLeft = Math.max(0, list.scrollWidth - list.clientWidth)
        const targetLeft = Math.max(0, Math.min(
            maxLeft,
            list.scrollLeft + topicRect.left + (topicRect.width / 2)
                - listRect.left - (listRect.width / 2),
        ))
        const startLeft = list.scrollLeft
        const distance = targetLeft - startLeft
        if (Math.abs(distance) < 1) return

        const startedAt = performance.now()
        const step = now => {
            const progress = Math.min((now - startedAt) / TOPIC_SCROLL_DURATION, 1)
            const easedProgress = 1 - ((1 - progress) ** 3)
            list.scrollLeft = startLeft + (distance * easedProgress)
            if (progress < 1) {
                this._topicScrollFrame = requestAnimationFrame(step)
            } else {
                this._topicScrollFrame = null
            }
        }
        this._topicScrollFrame = requestAnimationFrame(step)
    }

    cancelProgrammaticScroll() {
        if (this._topicScrollFrame === null) return

        cancelAnimationFrame(this._topicScrollFrame)
        this._topicScrollFrame = null
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

        this.scheduleUnreadCountRefresh()

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
            topicEl.querySelector('.topic-unread-badge')?.remove()
        }

        const topic = [...(this.topics || []), ...(this.archivedTopics || [])]
            .find(candidate => String(candidate.id) === String(topicId))
        if (topic) topic.unread_count = 0

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
    applySelection(id, { pick = true, persist = true, pending = false } = {}) {
        if (persist) this.serverLastTopicId = id ? String(id) : ""
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
            this._pickTopicId = this.serverLastTopicId
            if (pending) {
                this._pendingPick = {
                    creativeId: this._pickCreativeId,
                    topicId: this._pickTopicId,
                }
            }
        }
        if (persist) this.debounceSaveLastTopic(id)
    }

    // Bumped on every selection so an in-flight loadTopics() can tell whether
    // its answer predates a pick the user has since made.
    get selectionEpoch() {
        return this._selectionEpoch || 0
    }

    set selectionEpoch(value) {
        this._selectionEpoch = value
    }

    // Did a pick land after the load at `epoch` started, or is there still an
    // unsaved pick about the creative that load describes? A later load can
    // begin before the pick's debounce lands, so request age alone cannot tell
    // whether its answer predates the pick. The strip the click landed on,
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
        const hasNewerPick = this.selectionEpoch !== epoch
        const hasUnsavedPick = this._pendingPick &&
            String(this._pendingPick.creativeId) === String(creativeId)
        if (!hasNewerPick && !hasUnsavedPick) return false
        // creativeId is always truthy here — loadTopics() returns without it —
        // so a pick made before any strip was rendered fails this too.
        if (String(this._pickCreativeId) !== String(creativeId)) return false
        if (!this._pickTopicId) return true

        return [ ...(topics || []), ...(archivedTopics || []) ]
            .some(t => String(t.id) === String(this._pickTopicId))
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
        // A linked shell can close before this debounce fires. Closing clears
        // the cached effective origin, and reopening another shell before the
        // callback runs would otherwise claim that shell's raw id even though
        // the save belongs to the stream selected here. Capture the requested
        // creative too: it is the PATCH endpoint, not the effective stream.
        const effectiveCreativeId = this.effectiveCreativeId
        const creativeId = this.creativeId
        this._saveLastTopicTimer = setTimeout(() => {
            this.flushSaveLastTopic(id, effectiveCreativeId, creativeId)
        }, 500)
    }

    // Drop a queued save without sending it. The timer closes over the id it
    // was scheduled with, so a save that is no longer wanted cannot be talked
    // out of its value — only cancelled.
    cancelPendingSaveLastTopic() {
        if (this._saveLastTopicTimer !== undefined && this._saveLastTopicTimer !== null) {
            clearTimeout(this._saveLastTopicTimer)
            this._saveLastTopicTimer = null
        }
    }

    async flushSaveLastTopic(
        id,
        claimedEffectiveCreativeId = this.effectiveCreativeId,
        requestedCreativeId = this.creativeId
    ) {
        this.cancelPendingSaveLastTopic()
        if (!requestedCreativeId) return

        const creativeId = requestedCreativeId
        const effectiveCreativeId = claimedEffectiveCreativeId
        const clientId = this.newLastTopicSaveClientId()
        const pendingPick = this._pendingPick
        // The subscription the echo of this save would arrive on. The claim is
        // taken inside the callback below, which runs whenever the save ahead
        // of it finishes — by then the stream may already be a different one,
        // and a claim taken against a stream we have left is owed a message
        // that cannot arrive.
        const generation = this.subscriptionGenerationFor(effectiveCreativeId)
        // One save at a time. Two PATCHes in flight together are persisted in
        // whatever order the server finishes them, so the preference that
        // sticks need not be the last one picked. Waiting for the one in
        // flight is what makes the order they were picked in the order they
        // are written.
        this._saveChain = (this._saveChain || Promise.resolve()).then(async () => {
            // update_last_topic broadcasts to every session of this user, this
            // one included. Claim the echo here, before the request goes out —
            // the broadcast is sent server-side before the response is
            // rendered, so it can beat the save returning.
            const claimed = generation === this.subscriptionGenerationFor(effectiveCreativeId)
            if (claimed) {
                this.pendingSelfEchoes.push(clientId)
                this.pendingSelfEchoCreativeIds.set(clientId, String(effectiveCreativeId))
                this.pendingSelfEchoTopicIds.set(clientId, id ? String(id) : "")
                this.pendingSelfEchoPreviousTopicIds.set(
                    clientId,
                    this.lastKnownRemoteTopicIdFor(effectiveCreativeId) === undefined
                        ? (this.serverLastTopicId ? String(this.serverLastTopicId) : "")
                        : this.lastKnownRemoteTopicIdFor(effectiveCreativeId)
                )
                // A save can wait behind another request while the popup closes. It
                // takes its claim only when the queue reaches it, after the close
                // handler has already marked the claims that existed then. Its echo
                // will also be sent into that closed gap, so mark it at creation.
                if (this._popupClosed && !this.topicsSubscription) {
                    this.possiblyMissedPendingSelfEchoes.add(clientId)
                }
            }
            // A thrown fetch has an unknown outcome: the server may have saved
            // and broadcast before the connection failed, so keep its claim for
            // that delayed echo. An HTTP failure is definitive, however, and
            // update_last_topic returns before broadcasting in that case.
            const saveResult = await this.saveLastTopicWithTimeout(creativeId, id || null, clientId)
            const saved = saveResult === true || saveResult?.success === true
            const savedRevision = this.normalizeLastTopicRevision(saveResult?.lastTopicRevision)
            const savedRevisionIsCurrent = this.observeLastTopicRevision(
                effectiveCreativeId,
                savedRevision
            )
            const topicId = id ? String(id) : ""
            const saveRejected = saveResult === false || saveResult?.success === false
            const staleLastTopicSave = saveResult?.staleLastTopicSave === true
            if (claimed && saved) {
                // The Action Cable echo can arrive before this response. In that
                // case it has already consumed the claim and removed its metadata;
                // do not recreate an acknowledgement entry for a completed save.
                const hasPendingSelfEcho = this.pendingSelfEchoes.includes(clientId)
                if (hasPendingSelfEcho) {
                    this.saveAcknowledgementVersion += 1
                    this.pendingSelfEchoAcknowledgementVersions.set(
                        clientId,
                        this.saveAcknowledgementVersion
                    )
                    // The response can beat its Action Cable echo. Preserve the
                    // server-issued revision now so a delayed GET can order this
                    // acknowledged claim against a newer ABA snapshot.
                    if (savedRevision) {
                        this.pendingSelfEchoRemoteRevisions.set(clientId, savedRevision)
                    }
                }
                const currentCreativeId = String(this.creativeId)
                const currentStreamIsResolved = this.element.dataset.effectiveCreativeId ||
                    this.knownEffectiveCreativeIds.has(currentCreativeId)
                const subscribedToAnotherStream = this.topicsSubscription && currentStreamIsResolved &&
                    String(this.effectiveCreativeId) !== String(effectiveCreativeId)
                const possiblyMissedDuringDisconnect =
                    this.possiblyMissedPendingSelfEchoesDuringDisconnect.has(clientId)
                if ((this.possiblyMissedPendingSelfEchoes.has(clientId) && !this.topicsSubscription) ||
                    subscribedToAnotherStream ||
                    possiblyMissedDuringDisconnect) {
                    // update_last_topic broadcasts before it returns. With the popup
                    // closed, or after its stream was replaced, that echo was necessarily
                    // sent somewhere this controller can no longer receive it and cannot
                    // settle this claim.
                    // This completed save is also the remote baseline for the next
                    // queued save, which may have claimed after the popup closed.
                    this.setLastKnownRemoteTopicId(effectiveCreativeId, topicId)
                    if (possiblyMissedDuringDisconnect) {
                        this.retirePendingSelfEcho(clientId)
                    } else {
                        this.releasePendingSelfEcho(clientId)
                    }
                } else {
                    // The replacement subscription may have been active before this
                    // response beat the WebSocket message back to the browser. Keep the
                    // id to consume that echo, but do not use this acknowledged claim to
                    // override a later reopen snapshot.
                    // A completed save establishes the server value that the
                    // next claim was made from. Without moving this baseline,
                    // a later closed save compares its reopen snapshot to a
                    // value from before an earlier local save and mistakes the
                    // legitimate previous value for another session's update.
                    // Do not overwrite a newer Action Cable update after this
                    // save's echo has already been consumed: that echo records
                    // the baseline at broadcast time, and another message may
                    // have advanced it before the HTTP response arrived.
                    if (hasPendingSelfEcho && savedRevisionIsCurrent) {
                        this.setLastKnownRemoteTopicId(effectiveCreativeId, topicId)
                    }
                    this.acknowledgePendingSelfEcho(clientId)
                }
            }
            if (claimed && saveRejected) this.releasePendingSelfEcho(clientId)
            if (claimed && saveResult === null) {
                this.scheduleAmbiguousPendingSelfEchoRetirement(clientId)
            }
            const rejectedPendingPick = staleLastTopicSave && this._pendingPick === pendingPick &&
                String(pendingPick?.creativeId) === String(creativeId) &&
                pendingPick?.topicId === topicId
            if (rejectedPendingPick) this._pendingPick = null
            if (saveResult !== null) this.retryDeferredLastTopicReconciliation(effectiveCreativeId)
            if (saveResult !== false && this._pendingPick === pendingPick &&
                String(pendingPick?.creativeId) === String(creativeId) &&
                pendingPick?.topicId === topicId) {
                this._pendingPick = null
            }
        })
        return this._saveChain
    }

    // A timed-out fetch can still be running on Rails. Prefix each echo id with
    // a controller-local session and monotonically increasing sequence so Rails
    // can reject an older request if a later one from this controller commits
    // first. The trailing nonce keeps the Action Cable echo identifier unique.
    newLastTopicSaveClientId() {
        this._lastTopicSaveSessionId ||= this.lastTopicSaveSessionId()
        this._lastTopicSaveSequence = this.nextLastTopicSaveSequence()
        return `${this._lastTopicSaveSessionId}.${this._lastTopicSaveSequence}.${newClientId()}`
    }

    // A Turbo replacement creates a new controller while an earlier request can
    // still be running on Rails. Keep the fence identity and counter for this
    // browser tab so the server can reject that earlier request after the new
    // controller has saved a later selection.
    lastTopicSaveSessionId() {
        try {
            const sessionId = this.lastTopicSaveWindowSessionId()
            sessionStorage.setItem(LAST_TOPIC_SAVE_SESSION_STORAGE_KEY, sessionId)
            return sessionId
        } catch (_) {
            return newClientId()
        }
    }

    // sessionStorage survives a reload, but browsers copy it into a duplicated
    // tab. window.name belongs to one top-level browsing context and also
    // survives reloads, so it keeps Turbo replacements on one fence while a
    // copied tab starts a separate ordering stream.
    lastTopicSaveWindowSessionId() {
        const currentName = window.name || ""
        if (currentName.startsWith(LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX)) {
            const sessionId = currentName.slice(LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX.length)
            if (/^[A-Za-z0-9-]+$/.test(sessionId)) return sessionId
        }

        const sessionId = newClientId()
        window.name = `${LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX}${sessionId}`
        return sessionId
    }

    nextLastTopicSaveSequence() {
        try {
            const stored = Number(sessionStorage.getItem(LAST_TOPIC_SAVE_SEQUENCE_STORAGE_KEY))
            const previous = Number.isSafeInteger(stored) && stored >= 0 ? stored : 0
            const sequence = Math.max(this._lastTopicSaveSequence || 0, previous) + 1
            sessionStorage.setItem(LAST_TOPIC_SAVE_SEQUENCE_STORAGE_KEY, String(sequence))
            return sequence
        } catch (_) {
            return (this._lastTopicSaveSequence || 0) + 1
        }
    }

    // A request that never settles must not hold every later pick behind it.
    // Its server outcome remains ambiguous, so the caller still retains a short
    // lived echo claim just as it does for a rejected fetch.
    saveLastTopicWithTimeout(creativeId, topicId, clientId) {
        const abortController = new AbortController()
        const request = Promise.resolve(
            saveLastTopic(creativeId, topicId, clientId, abortController.signal)
        ).catch(() => null)
        let timeoutId
        const timedOutRequest = new Promise(resolve => {
            timeoutId = setTimeout(() => {
                // Do not advance the serialized queue while this request can still
                // reach Rails. An abort makes fetch settle before the next save starts.
                abortController.abort()
                request.then(resolve)
            }, SAVE_REQUEST_TIMEOUT)
        })

        return Promise.race([request, timedOutRequest]).finally(() => clearTimeout(timeoutId))
    }

    // The echo names the save it came from, so this is identity, not a guess.
    // Matching on the topic id instead would let a sibling session that picked
    // the same topic settle one of our claims, leaving our own echo to arrive
    // later looking like news and revert whatever the user picked meanwhile.
    consumeSelfEcho(clientId, lastTopicRevision) {
        if (!clientId) return false

        const index = this.pendingSelfEchoes.indexOf(clientId)
        if (index === -1) return false

        // An echo proves the save committed even when it wins the race with its
        // HTTP response. Keep its ordering data only while an older GET can still
        // arrive; otherwise that GET could restore the pre-save preference after
        // the response has cleared _pendingPick.
        this.saveAcknowledgementVersion += 1
        this.pendingSelfEchoAcknowledgementVersions.set(
            clientId,
            this.saveAcknowledgementVersion
        )
        const normalizedRevision = this.normalizeLastTopicRevision(lastTopicRevision)
        if (normalizedRevision) {
            this.pendingSelfEchoRemoteRevisions.set(clientId, normalizedRevision)
        }
        this.acknowledgedPendingSelfEchoes.add(clientId)
        this.pendingSelfEchoes.splice(index, 1)
        // Keep the closed-gap marker with the tombstone. A reopened GET can be
        // newer than this committed save even when its response races ahead of
        // the PATCH response; releasing this marker here would make that newer
        // sibling-session snapshot look stale and replay our old pick over it.
        this.settledSelfEchoes.add(clientId)
        this.discardSettledSelfEchoesNoLongerNeeded()
        return true
    }

    releasePendingSelfEcho(clientId) {
        const index = this.pendingSelfEchoes.indexOf(clientId)
        if (index === -1) return false

        this.pendingSelfEchoes.splice(index, 1)
        this.discardSelfEchoMetadata(clientId)
        return true
    }

    // A Turbo replacement clears controller-local claims while an earlier PATCH
    // can still commit. The save-session prefix belongs to this top-level tab,
    // so its orphaned echo remains ours and must not be applied as a sibling
    // update over the replacement controller's newer pick.
    isLastTopicSaveFromThisTab(clientId) {
        const match = String(clientId || "").match(/^([A-Za-z0-9-]+)\.([1-9]\d*)\.[A-Za-z0-9-]+$/)
        const currentName = window.name || ""
        if (!currentName.startsWith(LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX)) return false

        const sessionId = currentName.slice(LAST_TOPIC_SAVE_WINDOW_NAME_PREFIX.length)
        return Boolean(match) && /^[A-Za-z0-9-]+$/.test(sessionId) && match[1] === sessionId
    }

    // A retired ambiguous request can still have committed after its connection
    // failed. Its sequence is monotonic within a tab session, so one high-water
    // mark per session keeps all older late echoes non-actionable without retaining
    // one tombstone per failed save.
    retirePendingSelfEcho(clientId) {
        const released = this.releasePendingSelfEcho(clientId)
        if (released) this.observeRetiredSelfEcho(clientId)
        return released
    }

    lastTopicSaveClientIdParts(clientId) {
        const match = String(clientId || "").match(/^([A-Za-z0-9-]+)\.([1-9]\d*)\.[A-Za-z0-9-]+$/)
        if (!match) return null

        return { sessionId: match[1], sequence: Number(match[2]) }
    }

    observeRetiredSelfEcho(clientId) {
        const parts = this.lastTopicSaveClientIdParts(clientId)
        if (!parts) return

        const previous = this.retiredSelfEchoSequenceHighWaters.get(parts.sessionId) || 0
        if (parts.sequence > previous) {
            this.retiredSelfEchoSequenceHighWaters.set(parts.sessionId, parts.sequence)
        }
    }

    isRetiredSelfEcho(clientId) {
        const parts = this.lastTopicSaveClientIdParts(clientId)
        if (!parts) return false

        return parts.sequence <= (this.retiredSelfEchoSequenceHighWaters.get(parts.sessionId) || 0)
    }

    discardSelfEchoMetadata(clientId) {
        this.cancelAmbiguousPendingSelfEchoRetirement(clientId)
        this.pendingSelfEchoCreativeIds.delete(clientId)
        this.pendingSelfEchoTopicIds.delete(clientId)
        this.pendingSelfEchoPreviousTopicIds.delete(clientId)
        this.pendingSelfEchoAcknowledgementVersions.delete(clientId)
        this.pendingSelfEchoRemoteRevisions.delete(clientId)
        this.possiblyMissedPendingSelfEchoes.delete(clientId)
        this.possiblyMissedPendingSelfEchoesDuringDisconnect.delete(clientId)
        this.acknowledgedPendingSelfEchoes.delete(clientId)
        this.settledSelfEchoes.delete(clientId)
    }

    // A rejected fetch has an ambiguous server outcome, so retain its claim long
    // enough for a delayed self-echo. It cannot remain forever, though: a request
    // that never reached Rails has no echo or revision to resolve it, and would
    // otherwise defer every later revisioned snapshot on this stream.
    scheduleAmbiguousPendingSelfEchoRetirement(clientId) {
        if (!this.pendingSelfEchoes.includes(clientId)) return

        this.cancelAmbiguousPendingSelfEchoRetirement(clientId)
        const timeout = setTimeout(() => {
            this.ambiguousPendingSelfEchoRetirements.delete(clientId)
            const creativeId = this.pendingSelfEchoCreativeIds.get(clientId)
            if (creativeId === undefined ||
                this.acknowledgedPendingSelfEchoes.has(clientId) ||
                this.pendingSelfEchoRemoteRevisions.has(clientId)) return

            this.retirePendingSelfEcho(clientId)
            this.retryDeferredLastTopicReconciliation(creativeId)
        }, AMBIGUOUS_SAVE_CLAIM_TIMEOUT)
        this.ambiguousPendingSelfEchoRetirements.set(clientId, timeout)
    }

    cancelAmbiguousPendingSelfEchoRetirement(clientId) {
        const timeout = this.ambiguousPendingSelfEchoRetirements.get(clientId)
        if (timeout !== undefined) clearTimeout(timeout)
        this.ambiguousPendingSelfEchoRetirements.delete(clientId)
    }

    get ambiguousPendingSelfEchoRetirements() {
        return this._ambiguousPendingSelfEchoRetirements ||
            (this._ambiguousPendingSelfEchoRetirements = new Map())
    }

    get retiredSelfEchoSequenceHighWaters() {
        return this._retiredSelfEchoSequenceHighWaters ||
            (this._retiredSelfEchoSequenceHighWaters = new Map())
    }

    // An early echo can be the only proof that an in-flight GET predates a
    // committed save. Once every GET that started before it has finished, the
    // tombstone has no ordering work left and must not accumulate in a long-lived
    // popup controller. Compare the save version captured by each active load,
    // not its unrelated request sequence number.
    discardSettledSelfEchoesNoLongerNeeded() {
        for (const clientId of [...this.settledSelfEchoes]) {
            const acknowledgementVersion = this.pendingSelfEchoAcknowledgementVersions.get(clientId)
            const hasOlderLoad = [...this.activeLoadAcknowledgementVersions.values()].some(
                loadAcknowledgementVersion => loadAcknowledgementVersion < acknowledgementVersion
            )
            if (!hasOlderLoad) this.discardSelfEchoMetadata(clientId)
        }
    }

    // Ids of saves this client has made and not yet seen come back. The echo of
    // our own save is not news: it names what we already asked for, and by the
    // time it arrives the user may have picked something else — applying it
    // then reverts the newer pick and persists the older topic over it.
    get pendingSelfEchoes() {
        return this._pendingSelfEchoes || (this._pendingSelfEchoes = [])
    }

    get pendingSelfEchoCreativeIds() {
        return this._pendingSelfEchoCreativeIds || (this._pendingSelfEchoCreativeIds = new Map())
    }

    get pendingSelfEchoTopicIds() {
        return this._pendingSelfEchoTopicIds || (this._pendingSelfEchoTopicIds = new Map())
    }

    // The last preference observed from the server is the baseline for a save.
    // It belongs to an effective creative stream: a controller can move between
    // creatives before the next fetch resolves, and one stream's preference is
    // never evidence about another stream.
    get lastKnownRemoteTopicId() {
        return this.lastKnownRemoteTopicIdFor(this.effectiveCreativeId)
    }

    set lastKnownRemoteTopicId(value) {
        this.setLastKnownRemoteTopicId(this.effectiveCreativeId, value)
    }

    lastKnownRemoteTopicIdFor(creativeId) {
        return this.lastKnownRemoteTopicIds.get(String(creativeId))
    }

    setLastKnownRemoteTopicId(creativeId, value) {
        this.lastKnownRemoteTopicIds.set(String(creativeId), value ? String(value) : "")
    }

    get lastKnownRemoteTopicIds() {
        return this._lastKnownRemoteTopicIds || (this._lastKnownRemoteTopicIds = new Map())
    }

    // Action Cable is ordered only within a connection. A delayed older message
    // can therefore arrive after a newer GET, response, or broadcast. Keep the
    // server-issued revision per effective stream and never apply it backward.
    observeLastTopicRevision(creativeId, revision) {
        if (!revision) return true

        const streamCreativeId = String(creativeId)
        const previous = this.highestLastTopicRevisions.get(streamCreativeId)
        const comparison = this.compareLastTopicRevisions(revision, previous)
        if (comparison !== null && comparison < 0) return false
        if (comparison === null || comparison > 0) {
            this.highestLastTopicRevisions.set(streamCreativeId, revision)
        }
        return true
    }

    get highestLastTopicRevisions() {
        return this._highestLastTopicRevisions || (this._highestLastTopicRevisions = new Map())
    }

    // The server resolves TopicsChannel subscriptions for linked shells to their
    // origin stream. Keep that result separately from the popup-scoped dataset:
    // the latter is deliberately cleared while a replacement load is pending.
    get knownEffectiveCreativeIds() {
        return this._knownEffectiveCreativeIds || (this._knownEffectiveCreativeIds = new Map())
    }

    get pendingSelfEchoPreviousTopicIds() {
        return this._pendingSelfEchoPreviousTopicIds || (this._pendingSelfEchoPreviousTopicIds = new Map())
    }

    get pendingSelfEchoAcknowledgementVersions() {
        return this._pendingSelfEchoAcknowledgementVersions || (this._pendingSelfEchoAcknowledgementVersions = new Map())
    }

    // The preference row id distinguishes a record recreated after clearing the
    // selection; the per-row revision orders saves made while it exists. Together
    // they are a server-issued ordering token, rather than an inference from a
    // topic id that can repeat in an ABA change (Main -> Alpha -> Main).
    normalizeLastTopicRevision(value) {
        if (!Array.isArray(value) || value.length !== 2) return null
        const revision = value.map(Number)
        return revision.every(Number.isSafeInteger) ? revision : null
    }

    compareLastTopicRevisions(left, right) {
        if (!left || !right) return null
        return left[0] === right[0] ? left[1] - right[1] : left[0] - right[0]
    }

    get pendingSelfEchoRemoteRevisions() {
        return this._pendingSelfEchoRemoteRevisions || (this._pendingSelfEchoRemoteRevisions = new Map())
    }

    // Echoes normally remove their claims. A short-lived tombstone retains the
    // save order for GETs already in progress when the echo arrived.
    get settledSelfEchoes() {
        return this._settledSelfEchoes || (this._settledSelfEchoes = new Set())
    }

    get activeLoadAcknowledgementVersions() {
        return this._activeLoadAcknowledgementVersions || (this._activeLoadAcknowledgementVersions = new Map())
    }

    get saveAcknowledgementVersion() {
        return this._saveAcknowledgementVersion || 0
    }

    set saveAcknowledgementVersion(value) {
        this._saveAcknowledgementVersion = value
    }

    // These claims were already in flight when the popup unsubscribed. If their
    // response arrives while the popup remains closed, the broadcast necessarily
    // went into that gap. A replacement subscription can receive an echo when it
    // reopens before the response arrives, though.
    get possiblyMissedPendingSelfEchoes() {
        return this._possiblyMissedPendingSelfEchoes || (this._possiblyMissedPendingSelfEchoes = new Set())
    }

    // A broadcast sent after Action Cable disconnects is not replayed after the
    // connection returns. Keep unresolved saves until their HTTP outcome tells us
    // whether one could have been sent in that gap; acknowledged saves can be
    // retired immediately because their broadcast has already been sent.
    get possiblyMissedPendingSelfEchoesDuringDisconnect() {
        return this._possiblyMissedPendingSelfEchoesDuringDisconnect ||
            (this._possiblyMissedPendingSelfEchoesDuringDisconnect = new Set())
    }

    handleTopicsSubscriptionDisconnected() {
        const deferredCreativeIds = new Set()
        for (const clientId of [...this.pendingSelfEchoes]) {
            const creativeId = this.pendingSelfEchoCreativeIds.get(clientId)
            if (creativeId === undefined) continue

            if (!this.acknowledgedPendingSelfEchoes.has(clientId)) {
                this.possiblyMissedPendingSelfEchoesDuringDisconnect.add(clientId)
                continue
            }

            this.setLastKnownRemoteTopicId(creativeId, this.pendingSelfEchoTopicIds.get(clientId))
            this.retirePendingSelfEcho(clientId)
            deferredCreativeIds.add(creativeId)
        }
        for (const creativeId of deferredCreativeIds) {
            this.retryDeferredLastTopicReconciliation(creativeId)
        }
    }

    markPendingSelfEchoesAsPossiblyMissed() {
        for (const clientId of this.pendingSelfEchoes) {
            if (!this.acknowledgedPendingSelfEchoes.has(clientId)) {
                this.possiblyMissedPendingSelfEchoes.add(clientId)
            }
        }
    }

    // A successful response means the broadcast was already sent. Once this
    // popup unsubscribes, that echo cannot be replayed to settle its claim, so
    // retaining the acknowledgement metadata would leak it indefinitely.
    releaseAcknowledgedPendingSelfEchoes() {
        for (const clientId of [...this.pendingSelfEchoes]) {
            if (this.acknowledgedPendingSelfEchoes.has(clientId)) {
                this.releasePendingSelfEcho(clientId)
            }
        }
    }

    // A new requested creative initially has no client-side effective stream
    // entry. Its subscription may still resolve server-side to the stream of a
    // pending save, so do not release that claim until this GET supplies the
    // effective id. Once it does, an acknowledged claim on another stream can
    // no longer receive an echo on this subscription and must not be retained.
    releaseAcknowledgedPendingSelfEchoesOutside(effectiveCreativeId) {
        const streamCreativeId = String(effectiveCreativeId)
        for (const clientId of [...this.pendingSelfEchoes]) {
            if (this.pendingSelfEchoCreativeIds.get(clientId) !== streamCreativeId &&
                this.acknowledgedPendingSelfEchoes.has(clientId)) {
                this.releasePendingSelfEcho(clientId)
            }
        }
    }

    // A successful response proves the request committed. A close before the
    // response means the matching broadcast was missed and can be retired; an
    // open popup keeps its id long enough to consume an echo still in flight,
    // without allowing it to override a later reopen snapshot.
    get acknowledgedPendingSelfEchoes() {
        return this._acknowledgedPendingSelfEchoes || (this._acknowledgedPendingSelfEchoes = new Set())
    }

    acknowledgePendingSelfEcho(clientId) {
        if (this.pendingSelfEchoes.includes(clientId)) {
            this.possiblyMissedPendingSelfEchoes.delete(clientId)
            this.acknowledgedPendingSelfEchoes.add(clientId)
        }
    }

    latestPendingSelfEchoTopicIdFor(creativeId, snapshotTopicId, acknowledgedSaveVersion, snapshotTopicRevision) {
        const streamCreativeId = String(creativeId)
        let topicId = snapshotTopicId
        let found = false
        const orderingClaimIds = [ ...this.pendingSelfEchoes, ...this.settledSelfEchoes ]
        const remainingClaimIds = new Set(orderingClaimIds)

        // Saves are serialized, so each claim records the topic written by the
        // previous claim. A stale response can predate more than one completed
        // save; follow that chain instead of restoring only its first successor.
        // A claim acknowledged before this load began describes an older snapshot
        // and cannot advance it.
        for (;;) {
            const clientId = orderingClaimIds.find(id => {
                if (!remainingClaimIds.has(id)) return false
                const acknowledgedAfterLoadStarted =
                    this.acknowledgedPendingSelfEchoes.has(id) &&
                    this.pendingSelfEchoAcknowledgementVersions.get(id) > acknowledgedSaveVersion
                const revisionComparison = this.compareLastTopicRevisions(
                    this.pendingSelfEchoRemoteRevisions.get(id),
                    snapshotTopicRevision
                )
                return this.pendingSelfEchoCreativeIds.get(id) === streamCreativeId &&
                    (!this.acknowledgedPendingSelfEchoes.has(id) || acknowledgedAfterLoadStarted) &&
                    (revisionComparison === null
                        ? this.pendingSelfEchoPreviousTopicIds.get(id) === topicId
                        : revisionComparison > 0)
            })
            if (!clientId) return found ? topicId : undefined

            found = true
            remainingClaimIds.delete(clientId)
            topicId = this.pendingSelfEchoTopicIds.get(clientId)
        }
    }

    // A pick made before this replacement load normally outranks its answer: the
    // answer may simply predate the save. A claim that was in flight across a
    // close is the exception. When the snapshot has advanced from that save's
    // known baseline, the closed stream missed a newer cross-session write, so
    // replaying the local pick would immediately write the old topic back.
    pendingPickWasSupersededWhileClosed(creativeId, snapshotTopicId, snapshotTopicRevision) {
        if (!this._pendingPick) return false

        const streamCreativeId = String(creativeId)
        return [ ...this.pendingSelfEchoes, ...this.settledSelfEchoes ].some(clientId => {
            if (!this.possiblyMissedPendingSelfEchoes.has(clientId) ||
                this.pendingSelfEchoCreativeIds.get(clientId) !== streamCreativeId ||
                this.pendingSelfEchoTopicIds.get(clientId) !== this._pendingPick.topicId) return false

            const revisionComparison = this.compareLastTopicRevisions(
                snapshotTopicRevision,
                this.pendingSelfEchoRemoteRevisions.get(clientId)
            )
            return revisionComparison === null
                ? this.pendingSelfEchoPreviousTopicIds.get(clientId) !== snapshotTopicId
                : revisionComparison > 0
        })
    }

    // A revisioned snapshot can only be compared safely once every local save
    // involved in that comparison has supplied its revision. Until then an ABA
    // snapshot can look like the predecessor of an in-flight save by topic id.
    hasUnacknowledgedRevisionedSaveFor(creativeId, snapshotTopicRevision) {
        if (!snapshotTopicRevision) return false

        const streamCreativeId = String(creativeId)
        return this.pendingSelfEchoes.some(clientId =>
            this.pendingSelfEchoCreativeIds.get(clientId) === streamCreativeId &&
            !this.acknowledgedPendingSelfEchoes.has(clientId) &&
            !this.pendingSelfEchoRemoteRevisions.has(clientId)
        )
    }

    get deferredLastTopicReconciliations() {
        return this._deferredLastTopicReconciliations || (this._deferredLastTopicReconciliations = new Set())
    }

    retryDeferredLastTopicReconciliation(creativeId) {
        const streamCreativeId = String(creativeId)
        if (!this.deferredLastTopicReconciliations.has(streamCreativeId) ||
            String(this.effectiveCreativeId) !== streamCreativeId) return

        this.deferredLastTopicReconciliations.delete(streamCreativeId)
        this.loadTopics()
    }

    // Bumped for an individual stream when that stream is permanently gone. A
    // popup can temporarily subscribe to another creative, so invalidating that
    // subscription must not prevent a queued save for the original stream from
    // claiming its own echo when the user returns to it.
    subscriptionGenerationFor(creativeId) {
        const streamCreativeId = String(creativeId)
        if (!this.subscriptionGenerations.has(streamCreativeId)) {
            this.subscriptionGenerations.set(streamCreativeId, 0)
        }
        return this.subscriptionGenerations.get(streamCreativeId)
    }

    bumpSubscriptionGenerationFor(creativeId) {
        const streamCreativeId = String(creativeId)
        this.subscriptionGenerations.set(
            streamCreativeId,
            this.subscriptionGenerationFor(streamCreativeId) + 1
        )
    }

    get subscriptionGenerations() {
        return this._subscriptionGenerations || (this._subscriptionGenerations = new Map())
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
            // The migration is a save like any other. Giving it a client id
            // prevents its broadcast from being mistaken for another session's
            // update if the user chooses a topic before that echo arrives.
            this.flushSaveLastTopic(localValue)
        }
        localStorage.removeItem(key)
    }

    subscribe({ preservePendingSelfEchoes = false } = {}) {
        const creativeId = this.creativeId
        if (!creativeId) return

        if (this.topicsSubscription && this.subscribedCreativeId === String(creativeId)) return

        if (this.topicsSubscription) this.unsubscribe({ preservePendingSelfEchoes })

        this.subscribedCreativeId = String(creativeId)
        this.topicsSubscription = createSubscription(
            { channel: 'TopicsChannel', creative_id: this.creativeId },
            {
                received: (data) => this.handleTopicMessage(data),
                disconnected: () => this.handleTopicsSubscriptionDisconnected(),
                // A refused subscription is different: it is not retried, so
                // nothing outstanding or queued on this stream can ever settle.
                // Claims for another creative may still settle if the popup returns.
                rejected: () => this.dropPendingSelfEchoesForCreative(creativeId),
            }
        )
    }

    dropPendingSelfEchoes() {
        const streamCreativeIds = new Set([
            ...this.pendingSelfEchoCreativeIds.values(),
            ...this.subscriptionGenerations.keys(),
        ])
        this.pendingSelfEchoes.length = 0
        this.pendingSelfEchoCreativeIds.clear()
        this.pendingSelfEchoTopicIds.clear()
        this.pendingSelfEchoPreviousTopicIds.clear()
        this.pendingSelfEchoAcknowledgementVersions.clear()
        this.pendingSelfEchoRemoteRevisions.clear()
        this.possiblyMissedPendingSelfEchoes.clear()
        this.possiblyMissedPendingSelfEchoesDuringDisconnect.clear()
        this.acknowledgedPendingSelfEchoes.clear()
        this.settledSelfEchoes.clear()
        this.retiredSelfEchoSequenceHighWaters.clear()
        // Emptying the array cannot reach a claim that has not been taken yet.
        // A save waiting its turn on the chain takes one when it runs, and by
        // then every stream has gone; its stream generation tells it so.
        for (const creativeId of streamCreativeIds) {
            this.bumpSubscriptionGenerationFor(creativeId)
        }
    }

    dropPendingSelfEchoesForCreative(creativeId) {
        const streamCreativeId = String(creativeId)
        const clientIds = new Set([
            ...this.pendingSelfEchoes,
            ...this.settledSelfEchoes,
        ].filter(clientId => this.pendingSelfEchoCreativeIds.get(clientId) === streamCreativeId))

        this._pendingSelfEchoes = this.pendingSelfEchoes.filter(clientId => !clientIds.has(clientId))
        for (const clientId of clientIds) this.discardSelfEchoMetadata(clientId)
        this.bumpSubscriptionGenerationFor(streamCreativeId)
    }

    // A save can begin before a linked shell's topics response reveals that it
    // shares its origin's preference stream. Re-key that claim before pruning
    // so its identified echo remains recognisable on the resolved stream.
    remapPendingSelfEchoesForCreative(requestedCreativeId, effectiveCreativeId) {
        const requestedId = String(requestedCreativeId)
        const resolvedId = String(effectiveCreativeId)
        if (requestedId === resolvedId) return
        const requestedBaseline = this.lastKnownRemoteTopicIds.get(requestedId)
        if (requestedBaseline !== undefined) {
            if (!this.lastKnownRemoteTopicIds.has(resolvedId)) {
                this.lastKnownRemoteTopicIds.set(resolvedId, requestedBaseline)
            }
            this.lastKnownRemoteTopicIds.delete(requestedId)
        }
        const requestedRevision = this.highestLastTopicRevisions.get(requestedId)
        if (requestedRevision) {
            this.observeLastTopicRevision(resolvedId, requestedRevision)
            this.highestLastTopicRevisions.delete(requestedId)
        }

        for (const clientId of [ ...this.pendingSelfEchoes, ...this.settledSelfEchoes ]) {
            if (this.pendingSelfEchoCreativeIds.get(clientId) === requestedId) {
                this.pendingSelfEchoCreativeIds.set(clientId, resolvedId)
            }
        }
    }

    unsubscribe({ preservePendingSelfEchoes = false } = {}) {
        if (this.topicsSubscription) {
            this.topicsSubscription.unsubscribe()
            this.topicsSubscription = null
        }
        this.subscribedCreativeId = null
        // The stream is per creative, so echoes still owed to us on the one we
        // are leaving are not coming and nothing can settle their claims.
        // Unlike a dropped connection, there is no reconnect to wait for.
        if (!preservePendingSelfEchoes) this.dropPendingSelfEchoes()
    }

    handleTopicMessage(data) {
        if (!data) return

        const action = data.action || "created"

        if (action === "last_topic_changed") {
            // Broadcast is already scoped to the current user via user-specific channel
            const newTopicId = data.last_topic_id ? String(data.last_topic_id) : ""
            const lastTopicRevision = this.normalizeLastTopicRevision(data.last_topic_revision)
            // A retired ambiguous save remains non-actionable, but it can still have
            // committed after the request failed. Its revision must advance this
            // stream's high-water mark so an older in-flight GET cannot restore the
            // preference from before that save.
            if (!this.pendingSelfEchoes.includes(data.client_id) && this.isRetiredSelfEcho(data.client_id)) {
                this.observeLastTopicRevision(this.effectiveCreativeId, lastTopicRevision)
                return
            }
            // A linked shell can receive an echo before its load resolves the origin.
            // The claim already knows that effective stream, while effectiveCreativeId
            // still names the shell; advance the baseline on the claimed stream.
            const claimedEffectiveCreativeId = this.pendingSelfEchoCreativeIds.get(data.client_id) || this.effectiveCreativeId
            const isCurrentRevision = this.observeLastTopicRevision(
                claimedEffectiveCreativeId,
                lastTopicRevision
            )
            const consumedSelfEcho = this.consumeSelfEcho(data.client_id, lastTopicRevision)
            const orphanedSelfEcho = !consumedSelfEcho && this.isLastTopicSaveFromThisTab(data.client_id)
            const hasNewerPendingPick = this._pendingPick &&
                String(this.effectiveCreativeIdFor(this._pendingPick.creativeId)) === String(claimedEffectiveCreativeId)
            if (consumedSelfEcho || (orphanedSelfEcho && hasNewerPendingPick)) {
                if (isCurrentRevision) {
                    this.setLastKnownRemoteTopicId(claimedEffectiveCreativeId, newTopicId)
                }
                this.retryDeferredLastTopicReconciliation(claimedEffectiveCreativeId)
                return
            }
            if (!isCurrentRevision) return
            this.setLastKnownRemoteTopicId(this.effectiveCreativeId, newTopicId)
            // A deep-link restore may have queued a write even when this broadcast
            // repeats the preference already in serverLastTopicId. The sibling
            // session still established that preference, so the queued one-shot link
            // must not write itself back over it.
            if (this.hasDeepLinkSelection) this.cancelPendingSaveLastTopic()
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
                if (!this.hasDeepLinkSelection) {
                    // The save belonged to the controller Turbo replaced, not to a
                    // new pick in this one. Reflect its committed preference without
                    // creating another pending pick or writing it back to the server.
                    this.selectTopic(
                        newTopicId,
                        orphanedSelfEcho ? { pick: false, persist: false } : undefined
                    )
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
        // This arrived on the subscription for the creative currently open.
        // Unlike a local re-render of cached topics, it is not about the
        // outgoing creative whose strip may still be on screen during a switch.
        this.renderTopics(
            this.topics,
            this.canManageTopics,
            this.canCreateTopic,
            this.canSetPrimaryAgent,
            this.creativeId
        )

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
