// turbo_confirm — route Turbo's declarative `data-turbo-confirm` prompts through
// the in-app confirm dialog instead of the native window.confirm().
//
// Why: Rails/Turbo forms gate destructive submits with `data-turbo-confirm`.
// Turbo's default confirm method calls window.confirm(), which in the packaged
// desktop app (Tauri WKWebView) returns false with no UI — so the submit
// silently no-ops (e.g. token revoke, user delete, share removal) and looks
// like the button is broken. Converting hand-written confirm() calls does not
// cover these, because Turbo intercepts them before any of our code runs. The
// fix is a single global override of Turbo's confirm method.
//
// Returns a Promise<boolean>; Turbo awaits it before submitting (Turbo 8
// `config.forms.confirm`, with a fallback to the deprecated setConfirmMethod).

import { Turbo } from "@hotwired/turbo-rails"
import { confirmDialog } from "./utils/dialog"

// Turbo invokes this with (message, formElement, submitter). Style the confirm
// button as destructive when the submit deletes (the common case for
// data-turbo-confirm), so it matches the danger styling used elsewhere.
function turboConfirm(message, formElement, submitter) {
    const method = (
        submitter?.getAttribute?.("data-turbo-method") ||
        formElement?.getAttribute?.("data-turbo-method") ||
        formElement?.querySelector?.("input[name='_method']")?.value ||
        formElement?.getAttribute?.("method") ||
        ""
    ).toLowerCase()
    const danger = method === "delete" || method === "destroy"
    return confirmDialog(message, { danger })
}

// Install on both the bundled Turbo and any pre-existing global window.Turbo,
// mirroring turbo_stream_actions.js — the two can be distinct instances.
function installTurboConfirm(turbo) {
    if (!turbo) return
    if (turbo.config && turbo.config.forms) {
        turbo.config.forms.confirm = turboConfirm
    } else if (typeof turbo.setConfirmMethod === "function") {
        // Turbo < 8 fallback.
        turbo.setConfirmMethod(turboConfirm)
    }
}

installTurboConfirm(Turbo)
if (window.Turbo && window.Turbo !== Turbo) installTurboConfirm(window.Turbo)
