import { Controller } from '@hotwired/stimulus'
import CommonPopup from '../lib/common_popup'

export default class extends Controller {
    static targets = ['input']
    static values = {
        models: Array,
        menuId: String
    }

    connect() {
        this.menuElement = document.getElementById(this.menuIdValue)
        this.listElement = this.menuElement?.querySelector('.mention-results') ||
            this.menuElement?.querySelector('.common-popup-list')

        if (!this.menuElement || !this.listElement || this.modelsValue.length === 0) return

        this.popup = new CommonPopup(this.menuElement, {
            listElement: this.listElement,
            renderItem: (model) => `<div class="mention-item">${model}</div>`,
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

    focus() {
        clearTimeout(this.hideTimeout)
        this.show(this.inputTarget.value.trim())
    }

    blur() {
        this.hideTimeout = setTimeout(() => this.hide(), 150)
    }

    handleKeydown(event) {
        if (this.popup?.handleKey(event)) {
            event.preventDefault()
        }
    }

    show(term) {
        if (!this.popup) return

        const lowered = term.toLowerCase()
        const filtered = this.modelsValue.filter((model) => model.toLowerCase().includes(lowered))

        if (filtered.length === 0) {
            this.hide()
            return
        }

        this.popup.setItems(filtered)
        this.popup.showAt(this.inputTarget.getBoundingClientRect())
    }

    hide() {
        this.popup?.hide()
    }

    select(model) {
        this.inputTarget.value = model
        this.hide()
        this.inputTarget.focus()
        this.inputTarget.dispatchEvent(new Event('input', { bubbles: true }))
        this.inputTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
}
