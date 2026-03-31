import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../../lib/api/csrf_fetch"

const STATE_COLORS = {
    idle:                   "var(--text-muted)",
    running:                "var(--color-active)",
    pending_verification:   "var(--color-warning)",
    completed:              "var(--color-success)",
    stuck:                  "var(--color-danger)",
    max_reached:            "var(--color-warning)",
    paused:                 "var(--text-muted)"
}

const STATE_LABELS = {
    idle: "Idle",
    running: "Running",
    pending_verification: "Verifying",
    completed: "Completed",
    stuck: "Stuck",
    max_reached: "Max reached",
    paused: "Paused"
}

// Action label shown in tooltip: "Click to {action}"
const ACTION_LABELS = {
    pause: "pause",
    resume: "resume",
    restart: "restart"
}

export default class extends Controller {
    static targets = ["triggerButton"]

    connect() {
        this.enabled = false
        this.canWrite = false
        this._cachedData = null
        this._role = "none" // "container" | "task" | "none"
        this._loopState = null
        this._onCreativeUpdated = this._handleCreativeUpdated.bind(this)
        document.addEventListener('creative:updated', this._onCreativeUpdated)
    }

    disconnect() {
        document.removeEventListener('creative:updated', this._onCreativeUpdated)
    }

    get creativeId() {
        return this._creativeId || this.element.closest('#comments-popup')?.dataset?.creativeId
    }

    async onPopupOpened({ creativeId }) {
        this._creativeId = creativeId
        this.enabled = false
        this.canWrite = false
        this._cachedData = null
        this._role = "none"
        this._loopState = null
        this._hideAll()
        await this._loadTriggerState()
    }

    onPopupClosed() {
        this._creativeId = null
        this.enabled = false
        this.canWrite = false
        this._cachedData = null
        this._role = "none"
        this._loopState = null
        this._hideAll()
    }

    // Re-fetch trigger state when the current creative is updated via Turbo Stream
    async _handleCreativeUpdated(event) {
        const { creativeId, originId } = event.detail || {}
        const myId = this.creativeId
        if (!myId) return
        if (String(creativeId) === String(myId) || String(originId) === String(myId)) {
            await this._loadTriggerState()
        }
    }

    // Unified click handler — delegates based on role
    async triggerClick() {
        if (!this.canWrite) return
        if (this._role === "container") {
            await this._toggleContainer()
        } else if (this._role === "task") {
            await this._performTaskAction()
        }
    }

    async _toggleContainer() {
        const creativeId = this.creativeId
        if (!creativeId) return

        const newState = !this.enabled
        this.enabled = newState
        this._updateUI()

        try {
            const response = await csrfFetch(`/creatives/${creativeId}/trigger_action`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action_name: "toggle_container", enabled: newState })
            })

            if (!response.ok) {
                this.enabled = !newState
                this._updateUI()
            }
        } catch (e) {
            console.error("Failed to toggle drop trigger", e)
            this.enabled = !newState
            this._updateUI()
        }
    }

    async _performTaskAction() {
        const creativeId = this.creativeId
        if (!creativeId) return

        const actionName = this._actionForState(this._loopState)
        if (!actionName) return

        try {
            const response = await csrfFetch(`/creatives/${creativeId}/trigger_action`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action_name: actionName })
            })

            if (response.ok) {
                await this._loadTriggerState()
            }
        } catch (e) {
            console.error(`Failed to ${actionName} trigger`, e)
        }
    }

    _actionForState(state) {
        if (state === "running" || state === "pending_verification") return "pause"
        if (state === "paused" || state === "idle" || state === "stuck") return "resume"
        if (state === "completed" || state === "max_reached") return "restart"
        return null
    }

    async _loadTriggerState() {
        const creativeId = this.creativeId
        if (!creativeId) {
            return
        }

        try {
            const response = await fetch(`/creatives/${creativeId}.json`, { cache: 'no-store' })
            if (response.ok) {
                const json = await response.json()
                this._cachedData = json.data || {}
                this.canWrite = json.can_edit || false

                const triggerLoop = json.trigger_loop || null
                const trigger = this._cachedData.trigger || {}
                const isTriggerTask = json.is_trigger_task === true

                if (isTriggerTask || (triggerLoop && triggerLoop.state)) {
                    // Trigger task: parent is a trigger container
                    this._role = "task"
                    this._loopState = (triggerLoop && triggerLoop.state) ? triggerLoop.state : "idle"
                    this._loopIteration = triggerLoop?.current_iteration || 0
                    this._loopMax = triggerLoop?.max_iterations || 10
                    this.enabled = false
                } else if (trigger.on_child_enter !== undefined || json.can_edit) {
                    this._role = "container"
                    this._loopState = null
                    this.enabled = trigger.on_child_enter === true
                } else {
                    this._role = "none"
                    this._loopState = null
                }

                this._updateUI()
            } else {
            }
        } catch (e) {
            console.error("Failed to load trigger state", e)
        }
    }

    _hideAll() {
        if (this.hasTriggerButtonTarget) {
            this.triggerButtonTarget.style.display = 'none'
            this.triggerButtonTarget.classList.remove('trigger-running', 'drop-trigger-active')
        }
    }

    _updateUI() {
        if (!this.hasTriggerButtonTarget) return
        const btn = this.triggerButtonTarget

        if (this._role === "none") {
            btn.style.display = 'none'
            return
        }

        // Container toggle requires write permission; task status is visible to all
        if (this._role === "container" && !this.canWrite) {
            btn.style.display = 'none'
            return
        }

        btn.style.display = ''
        const icon = btn.querySelector('.trigger-zap-icon')

        if (this._role === "container") {
            // Container: simple toggle, zap color = active or muted
            btn.classList.toggle('drop-trigger-active', this.enabled)
            btn.classList.remove('trigger-running')
            if (icon) icon.style.color = ''
            btn.title = this.enabled ? 'Drop Trigger ON — click to disable' : 'Drop Trigger OFF — click to enable'

        } else if (this._role === "task") {
            const state = this._loopState || "idle"
            const color = STATE_COLORS[state] || "var(--text-muted)"
            const stateLabel = STATE_LABELS[state] || state
            const actionName = this._actionForState(state)
            const actionLabel = actionName ? ACTION_LABELS[actionName] : null

            // Set zap icon color
            btn.classList.remove('drop-trigger-active')
            if (icon) icon.style.color = color

            // Running animation
            btn.classList.toggle('trigger-running', state === "running")

            // Tooltip: state + action hint
            let tooltip = stateLabel
            if (this._loopIteration !== undefined && state !== "idle") {
                tooltip += ` (${this._loopIteration}/${this._loopMax})`
            }
            if (actionLabel && this.canWrite) {
                tooltip += ` — click to ${actionLabel}`
            }
            btn.title = tooltip
        }
    }
}
