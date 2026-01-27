import { Controller } from '@hotwired/stimulus'
import CommonPopup from '../lib/common_popup'

export default class extends Controller {
    static targets = ['input']
    static values = {
        creativeId: String,
        scope: String
    }

    connect() {
        this.popupElement = document.getElementById('share-user-suggestions')
        if (this.popupElement) {
            this.popup = new CommonPopup(this.popupElement, {
                onSelect: this.select.bind(this),
                renderItem: this.renderItem.bind(this)
            })
        }

        // Bind handleKey so we can remove it on disconnect if needed, 
        // although Stimulus handles controller instance methods well.
        // However, since we might need to pass it to other listeners:
        this.handleKey = this.handleKey.bind(this)
    }

    disconnect() {
        this.popup?.hide()
        this.popup = null
    }

    async input() {
        const query = this.inputTarget.value.trim()
        // Allow empty query if scope is present (contacts), otherwise require 1 char
        if (!this.scopeValue && query.length < 1) {
            this.popup?.hide()
            return
        }

        // Basic debounce
        clearTimeout(this.timeout)
        this.timeout = setTimeout(() => this.search(query), 300)
    }

    focus() {
        // Trigger search immediately on focus to show default list (e.g. contacts)
        this.input()
    }

    async search(query) {
        try {
            let url = `/users/search?q=${encodeURIComponent(query)}&limit=20`
            if (this.creativeIdValue) {
                url += `&creative_id=${this.creativeIdValue}`
            }
            if (this.scopeValue) {
                url += `&scope=${this.scopeValue}`
            }
            const response = await fetch(url, {
                headers: {
                    'Accept': 'application/json',
                    'X-Requested-With': 'XMLHttpRequest'
                }
            })

            if (!response.ok) return

            const users = await response.json()
            // format: [{ id, email, display_name, avatar_url }, ...] (assuming API structure)
            // If the API returns something else, I'll need to adjust.
            // Based on typical Rails users/search?q=..., it likely returns a list of users.
            // I'll assume they have email and display_name.

            const items = users.map(user => ({
                value: user.email,
                label: user.name || user.email, // fallback
                user: user
            }))

            if (items.length > 0) {
                this.popup?.setItems(items)
                this.popup?.showAt(this.inputTarget.getBoundingClientRect())
            } else {
                this.popup?.hide()
            }
        } catch (error) {
            console.error('Error searching users:', error)
        }
    }

    select(item) {
        this.inputTarget.value = item.value
        this.inputTarget.dispatchEvent(new Event('blur')) // Trigger validation if any
        this.popup?.hide()
    }

    handleKey(event) {
        console.log('ShareUserSearchController handleKey', event.key, this.popup?.isOpen(), this.popup?.items?.length)
        // Delegate key handling to the popup
        if (this.popup?.handleKey(event)) {
            // If popup handled it, query is consumed
            console.log('Popup handled key')
        }
    }

    renderItem(item) {
        const user = item.user
        const avatarUrl = user.avatar_url // if available, or we might need a placeholder
        // Safe guard avatar if not present. CommonPopup sends innerHTML, so we return a string.
        // We can try to use a similar style to the mentions.

        return `
      <div style="display: flex; align-items: center; gap: 8px; padding: 4px 8px;">
        ${avatarUrl ? `<img src="${avatarUrl}" class="avatar size-20" style="width:20px;height:20px;border-radius:50%;">` : ''}
        <div style="display: flex; flex-direction: column;">
          <span style="font-weight: 500;">${item.label}</span>
          <span style="font-size: 0.85em; color: #666;">${item.value}</span>
        </div>
      </div>
    `
    }
}
