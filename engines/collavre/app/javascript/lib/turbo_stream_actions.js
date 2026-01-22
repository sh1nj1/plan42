import { Turbo } from "@hotwired/turbo-rails"
import { application } from "../controllers/application"

Turbo.StreamActions.update_reactions = function () {
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
            // Find the stimulus controller instance using the global application instance
            const controller = application.getControllerForElementAndIdentifier(element, "comment")
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
}
