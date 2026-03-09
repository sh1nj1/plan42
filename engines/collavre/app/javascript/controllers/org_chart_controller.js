import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "shareContainer" ]

  updatePermission(event) {
    const select = event.target
    const url = select.dataset.updateUrl
    const permission = select.value
    const originalClass = select.className

    // Update visual class immediately
    select.className = select.className.replace(/org-chart-permission-\w+/g, "")
    select.classList.add("org-chart-permission-select", `org-chart-permission-${permission}`)

    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content,
        "Accept": "application/json"
      },
      body: JSON.stringify({ permission })
    }).then(response => {
      if (!response.ok) throw new Error("Failed")
    }).catch(() => {
      select.className = originalClass
      location.reload()
    })
  }

  openShareModal(event) {
    const btn = event.currentTarget
    const sharesUrl = btn.dataset.sharesUrl

    fetch(sharesUrl, {
      headers: { "Accept": "text/html" }
    })
      .then(r => r.text())
      .then(html => {
        this.shareContainerTarget.innerHTML = html
        this.#initializeModal()
      })
  }

  closeShareModal() {
    const modal = document.getElementById("share-creative-modal")
    if (modal) {
      modal.style.display = "none"
      document.body.classList.remove("no-scroll")
    }
    this.shareContainerTarget.innerHTML = ""
  }

  // Private

  #initializeModal() {
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return

    modal.style.display = "flex"
    document.body.classList.add("no-scroll")

    // Bind close button
    const closeBtn = document.getElementById("close-share-modal")
    if (closeBtn) {
      closeBtn.onclick = () => this.closeShareModal()
    }

    // Close on backdrop click
    modal.onclick = (e) => {
      if (e.target === modal) this.closeShareModal()
    }

    // Initialize invite link button
    this.#initializeInviteLink()
  }

  #initializeInviteLink() {
    const inviteLinkBtn = document.getElementById("creative-invite-link")
    if (!inviteLinkBtn) return

    inviteLinkBtn.onclick = () => {
      const creativeId = inviteLinkBtn.dataset.creativeId
      const permissionSelect = document.getElementById("share-permission")
      const permission = permissionSelect ? permissionSelect.value : "read"
      const permissionLabel = permissionSelect ? permissionSelect.options[permissionSelect.selectedIndex].text : ""
      const noAccessMessage = inviteLinkBtn.dataset.noAccessMessage
      const copiedTemplate = inviteLinkBtn.dataset.copiedTemplate

      if (permission === "no_access") {
        alert(noAccessMessage)
        return
      }

      fetch("/invite", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: JSON.stringify({ creative_id: creativeId, permission })
      })
        .then(r => r.json())
        .then(data => {
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(data.url).then(() => {
              alert(copiedTemplate.replace("__PERMISSION__", permissionLabel))
            })
          }
        })
    }
  }
}
