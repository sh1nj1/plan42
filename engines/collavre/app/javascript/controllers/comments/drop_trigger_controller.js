import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
    static targets = ["toggleButton"]

    connect() {
        this.enabled = false
        this.canWrite = false
    }

    get creativeId() {
        return this.element.closest('#comments-popup')?.dataset?.creativeId
    }

    async onPopupOpened({ creativeId }) {
        this.enabled = false
        this.canWrite = false
        this._updateButtonState()
        await this._loadTriggerState()
    }

    onPopupClosed() {
        this.enabled = false
        this.canWrite = false
        this._updateButtonState()
    }

    async toggle() {
        const creativeId = this.creativeId
        if (!creativeId || !this.canWrite) return

        const newState = !this.enabled
        this.enabled = newState
        this._updateButtonState()

        try {
            // Fetch current data first to preserve other fields
            const currentData = await this._fetchCreativeData()
            const newData = {
                ...currentData,
                trigger: { ...(currentData.trigger || {}), on_child_enter: newState }
            }

            const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
            const response = await fetch(`/creatives/${creativeId}/update_metadata`, {
                method: 'PATCH',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'X-CSRF-Token': csrfToken
                },
                body: new URLSearchParams({ data: JSON.stringify(newData) })
            })

            if (!response.ok) {
                // Revert on failure
                this.enabled = !newState
                this._updateButtonState()
            }
        } catch (e) {
            console.error("Failed to toggle drop trigger", e)
            this.enabled = !newState
            this._updateButtonState()
        }
    }

    async _loadTriggerState() {
        const creativeId = this.creativeId
        if (!creativeId) return

        try {
            const response = await fetch(`/creatives/${creativeId}.json`)
            if (response.ok) {
                const json = await response.json()
                this.enabled = json.data?.trigger?.on_child_enter === true
                this.canWrite = json.can_edit || false
                this._updateButtonState()
            }
        } catch (e) {
            console.error("Failed to load drop trigger state", e)
        }
    }

    async _fetchCreativeData() {
        const creativeId = this.creativeId
        if (!creativeId) return {}

        try {
            const response = await fetch(`/creatives/${creativeId}.json`)
            if (response.ok) {
                const json = await response.json()
                return json.data || {}
            }
        } catch (e) { /* ignore */ }
        return {}
    }

    _updateButtonState() {
        if (!this.hasToggleButtonTarget) return

        const btn = this.toggleButtonTarget
        // Only show for users with write permission
        btn.style.display = this.canWrite ? '' : 'none'
        btn.classList.toggle('drop-trigger-active', this.enabled)
        btn.title = this.enabled
            ? (btn.dataset.titleOn || 'Drop Trigger enabled')
            : (btn.dataset.titleOff || 'Drop Trigger disabled')
    }
}
