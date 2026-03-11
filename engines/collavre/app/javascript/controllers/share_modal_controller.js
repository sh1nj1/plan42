import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]

  connect() {
    if (!this.hasContainerTarget) {
      this.globalContainer = document.createElement("div")
      this.globalContainer.dataset.shareModalTarget = "container"
      document.body.appendChild(this.globalContainer)
    }

    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)

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

    this.currentSharesUrl = sharesUrl

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
      const shareBtn = document.getElementById("share-creative-btn")
      if (shareBtn) {
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

    const closeBtn = document.getElementById("close-share-modal")
    if (closeBtn) {
      closeBtn.onclick = () => this.close()
    }

    modal.onclick = (e) => {
      if (e.target === modal) this.close()
    }

    this.#initializeForm()
    this.#initializeDeleteButtons()
    this.#initializeInviteLink()
  }

  #initializeForm() {
    const form = document.getElementById("share-creative-form")
    if (!form) return

    form.addEventListener("submit", (e) => {
      e.preventDefault()
      const formData = new FormData(form)
      const email = formData.get("user_email")
      const permission = formData.get("permission")
      const submitBtn = form.querySelector("button[type='submit']")
      if (submitBtn) submitBtn.disabled = true

      // Optimistic UI: add a pending entry immediately
      const pendingEl = this.#addPendingEntry(email, permission)

      // Clear the email input
      const emailInput = form.querySelector("#share-user-email")
      if (emailInput) emailInput.value = ""
      if (submitBtn) submitBtn.disabled = false

      fetch(form.action, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: formData
      })
        .then(r => r.json().then(data => ({ status: r.status, data })))
        .then(({ status, data }) => {
          // Remove pending entry
          if (pendingEl) pendingEl.remove()

          if (status >= 200 && status < 300) {
            this.#showMessage(data.notice, "success")
            // Refresh to get accurate server-rendered list
            this.#refreshModal()
          } else {
            this.#showMessage(data.error, "error")
          }
        })
        .catch(() => {
          if (pendingEl) pendingEl.remove()
          this.#showMessage("An error occurred", "error")
        })
    })
  }

  #addPendingEntry(email, permission) {
    if (!email) return null
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return null

    // Find or create the shared list section
    let listSection = modal.querySelector(".share-grid")
    if (!listSection) {
      const popupBox = modal.querySelector(".popup-box")
      if (!popupBox) return null
      const section = document.createElement("div")
      section.style.marginTop = "1em"
      const strong = document.createElement("strong")
      strong.textContent = "..."
      section.appendChild(strong)
      listSection = document.createElement("ul")
      listSection.className = "share-grid"
      section.appendChild(listSection)
      popupBox.appendChild(section)
    }

    const li = document.createElement("li")
    li.className = "share-modal-pending"
    li.innerHTML = `
      <span><span class="avatar share-avatar" style="display:inline-block;width:20px;height:20px;border-radius:50%;background:var(--surface-3,#ddd);text-align:center;line-height:20px;font-size:10px;">${email[0].toUpperCase()}</span></span>
      <span>${this.#escapeHtml(email)}</span>
      <span style="opacity:0.5">${this.#escapeHtml(permission)}</span>
      <span><span class="share-modal-spinner"></span></span>
    `
    listSection.appendChild(li)
    return li
  }

  #initializeDeleteButtons() {
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return

    // Find all delete forms
    const deleteForms = modal.querySelectorAll("form")
    deleteForms.forEach(form => {
      const methodInput = form.querySelector("input[name='_method'][value='delete']")
      if (!methodInput) return

      form.addEventListener("submit", (e) => {
        e.preventDefault()

        // Check for confirm dialog - turbo_confirm can be on the form or button
        const confirmMessage = form.dataset.turboConfirm
          || form.querySelector("button[type='submit']")?.dataset?.turboConfirm
          || form.querySelector("button")?.dataset?.confirm
        if (confirmMessage && !window.confirm(confirmMessage)) return

        // Optimistic UI: fade out the parent li
        const listItem = form.closest("li")
        if (listItem) {
          listItem.style.opacity = "0.3"
          listItem.style.pointerEvents = "none"
        }

        fetch(form.action, {
          method: "DELETE",
          headers: {
            "Accept": "application/json",
            "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
          }
        })
          .then(r => {
            if (r.ok) {
              // Optimistic: remove the item
              if (listItem) listItem.remove()
              // Refresh in background for accuracy
              this.#refreshModal()
            } else {
              // Revert optimistic change
              if (listItem) {
                listItem.style.opacity = "1"
                listItem.style.pointerEvents = ""
              }
              return r.json().then(data => {
                this.#showMessage(data.error, "error")
              })
            }
          })
          .catch(() => {
            if (listItem) {
              listItem.style.opacity = "1"
              listItem.style.pointerEvents = ""
            }
            this.#showMessage("An error occurred", "error")
          })
      })
    })
  }

  #refreshModal() {
    if (!this.currentSharesUrl) return

    fetch(this.currentSharesUrl, {
      headers: { "Accept": "text/html" }
    })
      .then(r => r.text())
      .then(html => {
        this.container.innerHTML = html
        this.#initializeModal()
      })
      .catch(err => {
        console.error("share-modal: Failed to refresh modal", err)
      })
  }

  #showMessage(text, type) {
    if (!text) return
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return

    const existing = modal.querySelector(".share-modal-message")
    if (existing) existing.remove()

    const msg = document.createElement("div")
    msg.className = `share-modal-message share-modal-message-${type}`
    msg.textContent = text

    const title = modal.querySelector("h2")
    if (title) {
      title.insertAdjacentElement("afterend", msg)
    } else {
      modal.querySelector(".popup-box")?.prepend(msg)
    }

    setTimeout(() => msg.remove(), 4000)
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
            copyPromise.then(() => {
              this.#showMessage(copiedTemplate.replace("__PERMISSION__", permissionLabel), "success")
            })
          }
        })
        .catch(err => {
          console.error("Failed to create invite link", err)
        })
    }
  }

  #escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  #dispatchEvent(eventName) {
    this.element.dispatchEvent(new CustomEvent(eventName, {
      bubbles: true,
      detail: {}
    }))
  }
}
