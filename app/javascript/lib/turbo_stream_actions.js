import { Turbo } from "@hotwired/turbo-rails"

Turbo.StreamActions.update_reactions = function () {
    const targetId = this.getAttribute("target")
    const dataJSON = this.getAttribute("data")

    if (!targetId || !dataJSON) return

    try {
        const data = JSON.parse(dataJSON)
        const element = document.getElementById(targetId)

        if (element) {
            // Find the stimulus controller instance
            // We assume the element itself has the 'comment' controller or is part of it
            // In this case, the target is the comment element which has data-controller="comment"
            const controller = element.application.getControllerForElementAndIdentifier(element, "comment")
            if (controller && typeof controller.updateReactionsUI === 'function') {
                controller.updateReactionsUI(data)
            }
        }
    } catch (e) {
        console.error("Failed to process update_reactions stream action", e)
    }
}
