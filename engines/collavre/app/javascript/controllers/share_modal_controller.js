import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]

  connect() {
    // Create global container appended to body for proper z-index stacking
    if (!this.hasContainerTarget) {
      this.globalContainer = document.createElement("div")
      this.globalContainer.dataset.shareModalTarget = "container"
      document.body.appendChild(this.globalContainer)
    }

    // Listen for escape key
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)

    // Check for open_share query param
    this.checkOpenShareParam()
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    if (this.globalContainer) {
      this.globalContainer.remove()
    }
  }

  get container() {
    return this.hasContainerTarget ? this.containerTarget : this.globalContainer
  }

  open(event) {
    const btn = event.currentTarget
    const sharesUrl = btn.dataset.shareModalUrlParam || btn.dataset.sharesUrl

    if (!sharesUrl) {
      console.error("share-modal: No shares URL provided")
      return
    }

    fetch(sharesUrl, {
      headers: { "Accept": "text/html" }
    })
      .then(r => r.text())
      .then(html => {
        this.container.innerHTML = html
        this.#initializeModal()
        this.#dispatchEvent("share-modal:opened")
      })
      .catch(err => {
        console.error("share-modal: Failed to load modal", err)
      })
  }

  close() {
    const modal = document.getElementById("share-creative-modal")
    if (modal) {
      modal.style.display = "none"
      document.body.classList.remove("no-scroll")
    }
    if (this.container) {
      this.container.innerHTML = ""
    }
    this.#dispatchEvent("share-modal:closed")
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      const modal = document.getElementById("share-creative-modal")
      if (modal && modal.style.display === "flex") {
        this.close()
      }
    }
  }

  checkOpenShareParam() {
    const params = new URLSearchParams(window.location.search)
    if (params.get("open_share") === "true") {
      // Find a share button to trigger
      const shareBtn = document.getElementById("share-creative-btn")
      if (shareBtn) {
        // Dispatch a click event to open the modal
        shareBtn.click()
      }
    }
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
      closeBtn.onclick = () => this.close()
    }

    // Close on backdrop click
    modal.onclick = (e) => {
      if (e.target === modal) this.close()
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
          const plan42Copy = window.Plan42 && window.Plan42.copyTextToClipboard
          let copyPromise = null
          if (plan42Copy) {
            copyPromise = plan42Copy(data.url)
          } else if (navigator.clipboard && navigator.clipboard.writeText) {
            copyPromise = navigator.clipboard.writeText(data.url)
          }
          if (copyPromise) {
            copyPromise.then(function() {
              alert(copiedTemplate.replace("__PERMISSION__", permissionLabel))
            })
          }
        })
        .catch(err => {
          console.error("Failed to create invite link", err)
        })
    }
  }

  #dispatchEvent(eventName) {
    this.element.dispatchEvent(new CustomEvent(eventName, {
      bubbles: true,
      detail: {}
    }))
  }
}
