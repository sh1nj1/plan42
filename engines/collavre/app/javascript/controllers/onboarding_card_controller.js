import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { workspace: Boolean }

  connect() {
    if (!this.workspaceValue) return

    const params = new URLSearchParams(window.location.search)
    const action = params.get("onboarding_action")
    const targetId = params.get("onboarding_target_id")

    if (action === "progress" && targetId) {
      this._waitFor(`[creative-id="${CSS.escape(targetId)}"] [data-progress-toggle]`, (element) => {
        element.classList.add("onboarding-progress-highlight")
        element.scrollIntoView({ block: "center", behavior: "smooth" })
        element.focus({ preventScroll: true })
      })
    } else if (action === "edit" && targetId) {
      this._waitFor(`creative-tree-row[creative-id="${CSS.escape(targetId)}"]`, (row) => {
        row.dispatchEvent(new CustomEvent("creative-edit-click", {
          detail: {
            creativeId: targetId,
            component: row,
            treeElement: row.querySelector(".creative-tree")
          },
          bubbles: true,
          composed: true
        }))
      })
    } else if (action === "chat" || action === "mention") {
      this._waitFor("#new-comment-form textarea", (textarea) => {
        textarea.focus()
        if (action === "mention" && !textarea.value.includes("@")) {
          textarea.value = `@${textarea.value}`
          textarea.setSelectionRange(1, 1)
          textarea.dispatchEvent(new Event("input", { bubbles: true }))
        }
      })
    }
  }

  disconnect() {
    this._observer?.disconnect()
    clearTimeout(this._timeout)
  }

  _waitFor(selector, callback) {
    const existing = document.querySelector(selector)
    if (existing) {
      callback(existing)
      return
    }

    this._observer = new MutationObserver(() => {
      const element = document.querySelector(selector)
      if (!element) return

      this._observer.disconnect()
      clearTimeout(this._timeout)
      callback(element)
    })
    this._observer.observe(document.body, { childList: true, subtree: true })
    this._timeout = setTimeout(() => this._observer?.disconnect(), 10000)
  }
}
