import { createConsumer } from "collavre/services/cable.js"
import * as ActionCable from "@rails/actioncable"

// Explicitly set the consumer for Turbo Rails to ensure the singleton is used
// even when modules are bundled in isolation.
import { setConsumer } from "../../node_modules/@hotwired/turbo-rails/app/javascript/turbo/cable.js"
if (setConsumer) {
    setConsumer(createConsumer())
}

if (typeof window !== "undefined") {
    if (!window.ActionCable) {
        window.ActionCable = { ...ActionCable }
    }
    window.ActionCable.createConsumer = createConsumer
}
