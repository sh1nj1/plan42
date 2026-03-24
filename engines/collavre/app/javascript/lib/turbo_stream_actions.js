import { Turbo } from "@hotwired/turbo-rails"

// Register custom actions on both the imported Turbo and the global window.Turbo
// to handle cases where the bundled Turbo instance differs from the runtime one.
function registerStreamAction(name, handler) {
    Turbo.StreamActions[name] = handler
    if (window.Turbo && window.Turbo.StreamActions && window.Turbo.StreamActions !== Turbo.StreamActions) {
        window.Turbo.StreamActions[name] = handler
    }
}

// Creative tree refresh: triggered when a shared creative is created/updated/destroyed
registerStreamAction("refresh_creative_tree", function () {
    const creativeId = this.getAttribute("creative-id")
    const action = this.getAttribute("change-action")
    console.log("[Turbo] refresh_creative_tree", { creativeId, action })

    // Dispatch event for any listening tree controller to refetch
    document.dispatchEvent(new CustomEvent('creative-sync:refetch', {
        detail: { creativeId: creativeId ? parseInt(creativeId, 10) : null, action },
        bubbles: true
    }))
})

registerStreamAction("update_reactions", function () {
    const targetId = this.getAttribute("target")
    const dataJSON = this.getAttribute("data")

    console.log("[Turbo] update_reactions action received", { targetId, dataJSON })

    if (!targetId || !dataJSON) {
        console.warn("[Turbo] update_reactions missing target or data")
        return
    }

    try {
        const data = JSON.parse(dataJSON)
        const element = document.getElementById(targetId)

        if (element) {
            // Find the stimulus controller instance using the global Stimulus application
            const controller = window.Stimulus?.getControllerForElementAndIdentifier(element, "comment")
            if (controller && typeof controller.updateReactionsUI === 'function') {
                console.log("[Turbo] calling updateReactionsUI", data)
                controller.updateReactionsUI(data)
            } else {
                console.warn("[Turbo] comment controller not found", { element, controller })
            }
        } else {
            console.warn("[Turbo] target element not found", targetId)
        }
    } catch (e) {
        console.error("Failed to process update_reactions stream action", e)
    }
})
