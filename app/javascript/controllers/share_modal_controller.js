import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "form", "list", "listContainer", "email", "permission"]
  static values = { creativeId: Number }

  open() {
    this.modalTarget.style.display = "flex"
    document.body.classList.add("no-scroll")
    this.load()
    const params = new URLSearchParams(window.location.search)
    const reqEmail = params.get("share_request")
    if (reqEmail && this.hasEmailTarget) {
      this.emailTarget.value = reqEmail
      this.emailTarget.dispatchEvent(new Event("blur"))
    }
  }

  close() {
    this.modalTarget.style.display = "none"
    document.body.classList.remove("no-scroll")
  }

  overlay(e) {
    if (e.target === this.modalTarget) {
      this.close()
    }
  }

  load() {
    const url = `/creatives/${this.creativeIdValue}/creative_shares.json?t=${Date.now()}`
    fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" })
      .then(r => (r.ok ? r.json() : []))
      .then(shares => {
        this.listTarget.innerHTML = ""
        shares.forEach(share => {
          const li = document.createElement("li")
          li.innerHTML = `
            <span>${share.user_name}</span>
            <span>${share.permission_name}</span>
            <span><a href="${share.creative.link}">${share.creative.title}</a></span>
            <span>${new Date(share.created_at).toLocaleString()}</span>
            <span><button data-action="share-modal#remove" data-share-id="${share.id}" class="delete-share-btn" style="padding:0 0.5em;">×</button></span>
          `
          this.listTarget.appendChild(li)
        })
        this.listContainerTarget.style.display = shares.length ? "block" : "none"
      })
  }

  submit(e) {
    e.preventDefault()
    const formData = new FormData(this.formTarget)
    fetch(this.formTarget.action, {
      method: "POST",
      headers: { Accept: "application/json" },
      body: formData
    })
      .then(r => r.json())
      .then(resp => {
        if (resp.error) {
          alert(resp.error)
        } else {
          if (resp.message) alert(resp.message)
          if (!resp.invited) this.load()
        }
        this.formTarget.reset()
      })
  }

  remove(e) {
    const id = e.target.dataset.shareId
    fetch(`/creatives/${this.creativeIdValue}/creative_shares/${id}`, {
      method: "DELETE",
      headers: { Accept: "application/json" }
    }).then(() => this.load())
  }
}

