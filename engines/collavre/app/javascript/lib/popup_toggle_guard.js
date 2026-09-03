// A button that toggles a CommonPopup receives its click *after* the popup's own
// outside-click handler has already closed it on mousedown. Left alone, that click
// reopens the popup and the button never closes anything. This guard records the
// pointerdown that closed a popup so the following click can be swallowed.
//
// Wire it up as: pointerdown->prepare, pointerup->finish, pointercancel->cancel,
// and check consume() at the top of the click handler.
export default class PopupToggleGuard {
    constructor() {
        this.pointerDown = false
        this.pointerId = undefined
        this.clearHandle = undefined
    }

    prepare(event, popupIsOpen) {
        if (event.isPrimary === false || event.button !== 0) return
        // Let every open popup receive this pointer event and perform its normal
        // outside-click cleanup. Only then is the following click ours to consume.
        if (!popupIsOpen) return

        this.pointerDown = true
        this.pointerId = event.pointerId
        event.currentTarget?.setPointerCapture?.(event.pointerId)
    }

    finish(event) {
        if (event.pointerId !== this.pointerId) return

        const rect = event.currentTarget.getBoundingClientRect()
        const releasedOutsideButton = event.clientX < rect.left || event.clientX > rect.right ||
            event.clientY < rect.top || event.clientY > rect.bottom
        if (releasedOutsideButton) {
            this.cancel(event)
        } else {
            // A completed activation dispatches click before the next task. Clear a
            // canceled in-button gesture afterwards so it cannot consume a later click.
            this.clearHandle = setTimeout(() => this.cancel(event), 0)
        }
    }

    cancel(event = {}) {
        if (event.pointerId != null && event.pointerId !== this.pointerId) return

        clearTimeout(this.clearHandle)
        this.clearHandle = undefined
        this.pointerDown = false
        this.pointerId = undefined
    }

    // True when the click that follows this gesture should be swallowed.
    consume() {
        if (!this.pointerDown) return false
        this.cancel()
        return true
    }
}
