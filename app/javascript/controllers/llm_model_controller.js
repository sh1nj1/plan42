import { Controller } from '@hotwired/stimulus'
import CommonPopup from 'collavre/lib/common_popup.js'
import { alertDialog } from 'collavre/lib/utils/dialog.js'

export default class extends Controller {
    static targets = ['input', 'vendor']
    static values = {
        models: Array,
        menuId: String,
        deleteLabel: String,
        deleteFailed: String
    }

    connect() {
        this.menuElement = document.getElementById(this.menuIdValue)
        this.listElement = this.menuElement?.querySelector('.mention-results') ||
            this.menuElement?.querySelector('.common-popup-list')

        if (!this.menuElement || !this.listElement) return

        this.popup = new CommonPopup(this.menuElement, {
            listElement: this.listElement,
            renderItem: (model) => this.renderModel(model),
            onSelect: this.select.bind(this)
        })
    }

    disconnect() {
        this.popup?.hide()
        this.popup = null
        clearTimeout(this.hideTimeout)
    }

    search() {
        this.show(this.inputTarget.value.trim())
    }

    vendorChanged() {
        clearTimeout(this.hideTimeout)
        this.show(this.inputTarget.value.trim())
    }

    focus() {
        clearTimeout(this.hideTimeout)
        this.show(this.inputTarget.value.trim())
    }

    blur() {
        this.hideTimeout = setTimeout(() => this.hide(), 150)
    }

    handleKeydown(event) {
        if (event.key === 'Tab' && !event.shiftKey && this.focusActiveDeleteButton()) {
            event.preventDefault()
            return
        }

        if (this.popup?.handleKey(event)) {
            event.preventDefault()
        }
    }

    focusActiveDeleteButton() {
        if (!this.popup?.isOpen()) return false

        const button = this.listElement
            .querySelector('.common-popup-item.active .llm-model-delete')
        if (!button) return false

        clearTimeout(this.hideTimeout)
        button.focus()
        return true
    }

    show(term) {
        if (!this.popup) return

        const lowered = term.toLowerCase()
        const vendor = this.vendorTarget.value
        const filtered = this.modelsValue.filter((model) => (
            model.vendor === vendor && model.name.toLowerCase().includes(lowered)
        ))

        if (filtered.length === 0) {
            this.hide()
            return
        }

        this.popup.setItems(filtered)
        this.bindDeleteButtons()
        this.popup.showAt(this.inputTarget.getBoundingClientRect())
    }

    hide() {
        this.popup?.hide()
    }

    select(model) {
        this.inputTarget.value = model.name
        this.hide()
        this.inputTarget.focus()
        this.inputTarget.dispatchEvent(new Event('input', { bubbles: true }))
        this.inputTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }

    prepareDelete(event) {
        event.preventDefault()
        event.stopPropagation()
    }

    async deleteModel(event) {
        event.preventDefault()
        event.stopPropagation()

        const id = Number(event.currentTarget.dataset.modelId)
        const model = this.modelsValue.find((candidate) => candidate.id === id)
        if (!model) return

        try {
            const response = await fetch(model.delete_url, {
                method: 'DELETE',
                headers: {
                    Accept: 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''
                }
            })
            if (!response.ok) throw new Error(`HTTP ${response.status}`)

            this.modelsValue = this.modelsValue.filter((candidate) => candidate.id !== id)
            this.show(this.inputTarget.value.trim())
        } catch (error) {
            await alertDialog(this.deleteFailedValue)
        }
    }

    renderModel(model) {
        const name = this.escapeHtml(model.name)
        const label = this.escapeHtml(`${this.deleteLabelValue}: ${model.name}`)

        return `<div class="mention-item llm-model-item">` +
            `<span class="llm-model-name">${name}</span>` +
            `<button type="button" class="llm-model-delete" data-model-id="${model.id}" aria-label="${label}" title="${label}">&times;</button>` +
            `</div>`
    }

    bindDeleteButtons() {
        this.listElement.querySelectorAll('.llm-model-delete').forEach((button) => {
            button.addEventListener('mousedown', this.prepareDelete.bind(this))
            button.addEventListener('touchstart', this.prepareDelete.bind(this))
            button.addEventListener('touchend', this.deleteModel.bind(this))
            button.addEventListener('click', this.deleteModel.bind(this))
            button.addEventListener('focus', () => clearTimeout(this.hideTimeout))
        })
    }

    escapeHtml(value) {
        return String(value)
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('"', '&quot;')
            .replaceAll("'", '&#39;')
    }
}
