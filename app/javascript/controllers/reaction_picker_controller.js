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
        // We need to capture the rect NOW before any layout shifts, 
        // but we need to wait for the picker to be unhidden to get its size.
        const targetRect = target.getBoundingClientRect()

        this.element.hidden = false

        // Wait for next frame to ensure rendering is complete and dimensions are correct
        requestAnimationFrame(() => {
            if (this.element.hidden) return // Closed in the meantime
            this.ensureOnScreen(targetRect)
        })
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
        const height = this.element.offsetHeight
        const width = this.element.offsetWidth
        const windowWidth = window.innerWidth
        const windowHeight = window.innerHeight

        // Requirement: "reaction 버튼 위에 표시되어야 해" (Must be displayed above)
        // Requirement: "화면을 나가지 않는 범위에서" (Within screen boundaries)

        // Strategy: Always attempt to place above.
        // Calculate ideal top position (above button with 8px gap)
        let top = targetRect.top - height - 8

        // 1. Top Boundary Check
        if (top < 10) {
            // If it goes off the top, clamp it to 10px from top.
            // This might overlap the button if the button is very high up, 
            // but strictly adheres to "within screen" and "as above as possible".
            top = 10
        }

        // 2. Bottom Boundary Check (rare, but if picker is huge)
        const maxTop = windowHeight - height - 10
        if (top > maxTop) {
            top = maxTop
        }

        let left = targetRect.left

        // 3. Horizontal Boundary Check
        // Left edge
        if (left < 10) {
            left = 10
        }
        // Right edge
        if (left + width > windowWidth - 10) {
            left = windowWidth - width - 10
        }
        // Final sanity check for left if width > windowWidth
        if (left < 10) left = 10

        this.element.style.top = `${top}px`
        this.element.style.left = `${left}px`
    }
}
