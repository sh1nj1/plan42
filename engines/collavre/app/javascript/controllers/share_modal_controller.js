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
    this.refreshTimer = null

    this.checkOpenShareParam()
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
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

  get #errorFallbackMessage() {
    const modal = document.getElementById("share-creative-modal")
    return modal?.dataset?.errorMessage || "An error occurred"
  }

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
    this.#initializePermissionSelects()
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
          if (pendingEl) pendingEl.remove()

          if (status >= 200 && status < 300) {
            this.#showMessage(data.notice, "success")
            this.#debouncedRefresh()
          } else {
            this.#showMessage(data.error, "error")
          }
        })
        .catch(() => {
          if (pendingEl) pendingEl.remove()
          this.#showMessage(this.#errorFallbackMessage, "error")
        })
    })
  }

  #addPendingEntry(email, permission) {
    if (!email) return null
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return null

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

    // Build DOM elements instead of innerHTML to avoid XSS
    const avatarSpan = document.createElement("span")
    const avatar = document.createElement("span")
    avatar.className = "avatar share-avatar"
    Object.assign(avatar.style, {
      display: "inline-block", width: "20px", height: "20px",
      borderRadius: "50%", background: "var(--surface-3,#ddd)",
      textAlign: "center", lineHeight: "20px", fontSize: "10px"
    })
    avatar.textContent = email[0].toUpperCase()
    avatarSpan.appendChild(avatar)

    const emailSpan = document.createElement("span")
    emailSpan.textContent = email

    const permSpan = document.createElement("span")
    permSpan.style.opacity = "0.5"
    permSpan.textContent = permission

    const spinnerSpan = document.createElement("span")
    const spinner = document.createElement("span")
    spinner.className = "share-modal-spinner"
    spinnerSpan.appendChild(spinner)

    li.append(avatarSpan, emailSpan, permSpan, spinnerSpan)
    listSection.appendChild(li)
    return li
  }

  #initializePermissionSelects() {
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return

    // Close any open dropdown when clicking outside
    modal.addEventListener("click", (e) => {
      if (!e.target.closest(".share-perm-wrapper")) {
        modal.querySelectorAll(".share-perm-dropdown").forEach(d => d.style.display = "none")
      }
    })

    const buttons = modal.querySelectorAll(".share-perm-btn")
    buttons.forEach(btn => {
      const wrapper = btn.closest(".share-perm-wrapper")
      const dropdown = wrapper.querySelector(".share-perm-dropdown")

      // Toggle dropdown on button click
      btn.addEventListener("click", (e) => {
        e.stopPropagation()
        // Close other dropdowns
        modal.querySelectorAll(".share-perm-dropdown").forEach(d => {
          if (d !== dropdown) d.style.display = "none"
        })
        dropdown.style.display = dropdown.style.display === "none" ? "block" : "none"
      })

      // Handle option selection
      dropdown.querySelectorAll(".share-perm-option").forEach(option => {
        option.addEventListener("click", (e) => {
          e.stopPropagation()
          const permission = option.dataset.value
          const url = btn.dataset.updateUrl
          const originalText = btn.textContent
          const originalClass = btn.className

          // Update button immediately
          btn.textContent = option.textContent.trim()
          btn.className = `share-perm-btn share-perm-${permission}`
          btn.dataset.current = permission
          dropdown.style.display = "none"

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
            btn.textContent = originalText
            btn.className = originalClass
            this.#showMessage(this.#errorFallbackMessage, "error")
          })
        })
      })
    })
  }

  #initializeDeleteButtons() {
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return

    const deleteForms = modal.querySelectorAll("form")
    deleteForms.forEach(form => {
      const methodInput = form.querySelector("input[name='_method'][value='delete']")
      if (!methodInput) return

      form.addEventListener("submit", (e) => {
        e.preventDefault()

        const confirmMessage = form.dataset.turboConfirm
          || form.querySelector("button[type='submit']")?.dataset?.turboConfirm
          || form.querySelector("button")?.dataset?.confirm
        if (confirmMessage && !window.confirm(confirmMessage)) return

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
              if (listItem) listItem.remove()
              this.#debouncedRefresh()
            } else {
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
            this.#showMessage(this.#errorFallbackMessage, "error")
          })
      })
    })
  }

  #debouncedRefresh() {
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => this.#refreshModal(), 300)
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

      const emailInput = document.getElementById("share-user-email")
      const email = emailInput ? emailInput.value.trim() : ""

      fetch("/invite", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: JSON.stringify({ creative_id: creativeId, permission, email: email || undefined })
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
          // Refresh modal to show the new invitation in the list
          this.#debouncedRefresh()
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
