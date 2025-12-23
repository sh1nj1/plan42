import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
    connect() {
        this.open = this.open.bind(this)
        window.addEventListener('reaction-picker:open', this.open)
        this.currentController = null
    }

    disconnect() {
        window.removeEventListener('reaction-picker:open', this.open)
    }

    open(event) {
        const { controller, target } = event.detail
        this.currentController = controller

        // Position the picker
        const rect = target.getBoundingClientRect()

        // Simple positioning: above the button, centered if possible
        // Adjust logic as needed for viewport edges
        this.element.style.top = `${rect.top - this.element.offsetHeight - 10}px`
        this.element.style.left = `${rect.left}px`

        this.element.hidden = false

        // Check if we need to flip styling or ensure it's visible (basic simple positioning first)
        // We might want to use a library like floating-ui later if complex positioning is needed.
        // For now, let's just make sure it's on screen.
        this.ensureOnScreen(rect)
    }

    close() {
        this.element.hidden = true
        this.currentController = null
    }

    select(event) {
        event.preventDefault()
        event.stopPropagation()
        const emoji = event.currentTarget.dataset.emoji

        if (this.currentController && emoji) {
            this.currentController.submitReaction(emoji, false)
        }

        this.close()
    }

    handleClickOutside(event) {
        if (this.element.hidden) return
        if (this.element.contains(event.target)) return

        // Check if the click was on the trigger button (optional, but good UX to toggle)
        // Actually, if we click outside, we just close.
        // Note: The event might be the open click itself? No, 'click@window' usually fires after.
        // We should ensure we don't close immediately if the event is the one that opened it.
        // Stimulus action 'click@window' might catch the trigger click if bubbling.
        // Usually we stopPropagation on the trigger, or checking if event.target is part of the detail.

        this.close()
    }

    ensureOnScreen(targetRect) {
        // Quick fix for positioning after showing (since offsetHeight needs display)
        // We set top/left before remove hidden, but offsetHeight might be 0 if hidden.
        // So we need to show it first (visibility hidden?) or use a trick.
        // Let's just adjust after unhiding.

        const height = this.element.offsetHeight
        const width = this.element.offsetWidth
        const windowWidth = window.innerWidth
        const windowHeight = window.innerHeight

        let top = targetRect.top - height - 8
        let left = targetRect.left

        // If top is offscreen, show below
        if (top < 10) {
            top = targetRect.bottom + 8
        }

        // If right is offscreen, shift left
        if (left + width > windowWidth - 10) {
            left = windowWidth - width - 10
        }

        this.element.style.top = `${top}px`
        this.element.style.left = `${left}px`
    }
}
