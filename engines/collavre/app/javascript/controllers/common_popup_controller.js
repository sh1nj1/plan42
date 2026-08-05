import { Controller } from '@hotwired/stimulus'
import CommonPopup from '../lib/common_popup'
import { escapeHtmlText } from '../utils/html_escape'

export default class extends Controller {
    static targets = ['list']
    static values = {
        closeOnOutsideClick: { type: Boolean, default: true }
    }

    connect() {
        this.popup = new CommonPopup(this.element, {
            listElement: this.listTarget,
            onSelect: this.select.bind(this),
            onClose: this.dispatchClose.bind(this),
            closeOnOutsideClick: this.closeOnOutsideClickValue,
            renderItem: this.renderItem.bind(this)
        })
    }

    disconnect() {
        this.popup?.hide()
        this.popup = null
    }

    open(anchorRect, boundsElement = null) {
        this.popup.showAt(anchorRect, boundsElement)
    }

    close() {
        this.popup.hide()
    }

    setItems(items) {
        this.popup.setItems(items)
    }

    handleKey(event) {
        return this.popup.handleKey(event)
    }

    // To be overridden or configured via callbacks if needed, 
    // but for now we dispatch an event that the parent controller can listen to.
    select(item) {
        this.dispatch('select', { detail: { item } })
    }

    dispatchClose(reason) {
        this.dispatch('close', { detail: { reason } })
    }

    // Default renderer, can be overridden by extending class or passing a specific renderer.
    // Emits plain text only, so it escapes; a subclass that returns real markup owns its own.
    renderItem(item) {
        return escapeHtmlText(item.label || item.value || JSON.stringify(item))
    }
}
