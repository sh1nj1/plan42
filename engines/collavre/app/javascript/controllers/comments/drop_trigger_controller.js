import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../../lib/api/csrf_fetch"

const CIRCUMFERENCE = 2 * Math.PI * 7 // r=7

const STATE_COLORS = {
    idle:                   "var(--text-muted)",
    running:                "var(--color-active)",
    pending_verification:   "var(--color-warning)",
    completed:              "var(--color-success)",
    stuck:                  "var(--color-danger)",
    max_reached:            "var(--color-warning)",
    paused:                 "var(--text-muted)"
}

// SVG icons for action buttons
const ICON_PAUSE = '<svg width="10" height="10" viewBox="0 0 10 10"><rect x="1" y="1" width="3" height="8" fill="currentColor"/><rect x="6" y="1" width="3" height="8" fill="currentColor"/></svg>'
const ICON_PLAY  = '<svg width="10" height="10" viewBox="0 0 10 10"><polygon points="2,1 9,5 2,9" fill="currentColor"/></svg>'
const ICON_RESTART = '<svg width="10" height="10" viewBox="0 0 10 10"><path d="M8 5a3 3 0 11-1-2.2" stroke="currentColor" stroke-width="1.2" fill="none"/><polygon points="6,1 8,3 6,3.5" fill="currentColor"/></svg>'

export default class extends Controller {
    static targets = ["toggleButton", "taskStatus", "progressRing", "progressFg", "actionBtn"]

    connect() {
        this.enabled = false
        this.canWrite = false
        this._cachedData = null
        this._role = "none" // "container" | "task" | "none"
        this._loopState = null
    }

    get creativeId() {
        return this.element.closest('#comments-popup')?.dataset?.creativeId
    }

    async onPopupOpened({ creativeId }) {
        this.enabled = false
        this.canWrite = false
        this._cachedData = null
        this._role = "none"
        this._loopState = null
        this._hideAll()
        await this._loadTriggerState()
    }

    onPopupClosed() {
        this.enabled = false
        this.canWrite = false
        this._cachedData = null
        this._role = "none"
        this._loopState = null
        this._hideAll()
    }

    async toggle() {
        const creativeId = this.creativeId
        if (!creativeId || !this.canWrite || this._role !== "container") return

        const newState = !this.enabled
        this.enabled = newState
        this._updateContainerUI()

        try {
            const response = await csrfFetch(`/creatives/${creativeId}/trigger_action`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: "toggle_container", enabled: newState })
            })

            if (!response.ok) {
                this.enabled = !newState
                this._updateContainerUI()
            }
        } catch (e) {
            console.error("Failed to toggle drop trigger", e)
            this.enabled = !newState
            this._updateContainerUI()
        }
    }

    async triggerAction() {
        const creativeId = this.creativeId
        if (!creativeId || !this.canWrite || this._role !== "task") return

        const state = this._loopState
        let actionName
        if (state === "running" || state === "pending_verification") {
            actionName = "pause"
        } else if (state === "paused" || state === "idle" || state === "stuck") {
            actionName = "resume"
        } else if (state === "completed" || state === "max_reached") {
            actionName = "restart"
        } else {
            return
        }

        try {
            const response = await csrfFetch(`/creatives/${creativeId}/trigger_action`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: actionName })
            })

            if (response.ok) {
                // Reload state
                await this._loadTriggerState()
            }
        } catch (e) {
            console.error(`Failed to ${actionName} trigger`, e)
        }
    }

    async _loadTriggerState() {
        const creativeId = this.creativeId
        if (!creativeId) return

        try {
            const response = await fetch(`/creatives/${creativeId}.json`)
            if (response.ok) {
                const json = await response.json()
                this._cachedData = json.data || {}
                this.canWrite = json.can_edit || false

                // trigger_loop comes from the creative's own data (not effective_origin)
                const triggerLoop = json.trigger_loop || null
                const trigger = this._cachedData.trigger || {}

                if (triggerLoop && triggerLoop.state) {
                    this._role = "task"
                    this._loopState = triggerLoop.state
                    this._loopIteration = triggerLoop.current_iteration || 0
                    this._loopMax = triggerLoop.max_iterations || 10
                    this.enabled = false
                } else {
                    this._role = "container"
                    this._loopState = null
                    this.enabled = trigger.on_child_enter === true
                }

                console.log("[drop-trigger] role:", this._role, "triggerLoop:", triggerLoop, "trigger:", trigger, "canWrite:", this.canWrite)
                this._updateUI()
            }
        } catch (e) {
            console.error("Failed to load trigger state", e)
        }
    }

    _hideAll() {
        if (this.hasToggleButtonTarget) this.toggleButtonTarget.style.display = 'none'
        if (this.hasTaskStatusTarget) this.taskStatusTarget.style.display = 'none'
    }

    _updateUI() {
        this._hideAll()
        if (this._role === "container") {
            this._updateContainerUI()
        } else if (this._role === "task") {
            this._updateTaskUI()
        }
    }

    _updateContainerUI() {
        if (!this.hasToggleButtonTarget) return
        const btn = this.toggleButtonTarget
        btn.style.display = this.canWrite ? '' : 'none'
        btn.classList.toggle('drop-trigger-active', this.enabled)
        btn.title = this.enabled
            ? (btn.dataset.titleOn || 'Drop Trigger enabled')
            : (btn.dataset.titleOff || 'Drop Trigger disabled')

        // Hide task UI
        if (this.hasTaskStatusTarget) this.taskStatusTarget.style.display = 'none'
    }

    _updateTaskUI() {
        // Hide container toggle
        if (this.hasToggleButtonTarget) this.toggleButtonTarget.style.display = 'none'

        if (!this.hasTaskStatusTarget) return
        const wrapper = this.taskStatusTarget
        wrapper.style.display = ''

        const state = this._loopState || "idle"
        const iteration = this._loopIteration || 0
        const max = this._loopMax || 10

        // Update progress ring
        if (this.hasProgressFgTarget) {
            const fg = this.progressFgTarget
            let ratio
            if (state === "completed" || state === "max_reached") {
                ratio = 1.0
            } else if (state === "idle") {
                ratio = 0.0
            } else {
                ratio = max > 0 ? Math.min(iteration / max, 1.0) : 0
            }
            const offset = CIRCUMFERENCE * (1 - ratio)
            fg.setAttribute("stroke-dashoffset", offset)
            fg.setAttribute("stroke", STATE_COLORS[state] || "var(--text-muted)")

            // Pulse animation for pending_verification
            fg.classList.toggle("trigger-progress-pulse", state === "pending_verification")
        }

        // Update tooltip
        const stateLabels = {
            idle: "Idle", running: "Running", pending_verification: "Verifying",
            completed: "Completed", stuck: "Stuck", max_reached: "Max reached",
            paused: "Paused"
        }
        wrapper.title = `${stateLabels[state] || state} (${iteration}/${max})`

        // Update action button
        if (this.hasActionBtnTarget) {
            const btn = this.actionBtnTarget
            if (!this.canWrite) {
                btn.style.display = 'none'
                return
            }

            btn.style.display = ''
            if (state === "running" || state === "pending_verification") {
                btn.innerHTML = ICON_PAUSE
                btn.title = "Pause"
            } else if (state === "paused" || state === "idle" || state === "stuck") {
                btn.innerHTML = ICON_PLAY
                btn.title = "Resume"
            } else if (state === "completed" || state === "max_reached") {
                btn.innerHTML = ICON_RESTART
                btn.title = "Restart"
            } else {
                btn.style.display = 'none'
            }
        }
    }
}
