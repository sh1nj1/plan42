import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "form"]
  static values = { editUrl: String, updateUrl: String, parentId: Number, siblingParentId: Number }

  connect() {
    this.isLoaded = false
  }

  showForm(event) {
    if (event) event.preventDefault()
    if (this.isLoaded) {
      this.toggleVisibility()
      this.focusEditor()
      return
    }
    fetch(this.editUrlValue + "?inline=1")
      .then(r => r.text())
      .then(html => {
        this.formTarget.innerHTML = html
        this.isLoaded = true
        this.toggleVisibility()
        this.setupAutoSave()
        this.focusEditor()
      })
  }

  toggleVisibility() {
    this.displayTarget.style.display = this.displayTarget.style.display === "none" ? "" : "none"
    this.formTarget.style.display = this.formTarget.style.display === "none" ? "" : "none"
  }

  setupAutoSave() {
    const form = this.formTarget.querySelector("form")
    if (!form) return
    form.addEventListener("trix-change", () => this.autoSave())
    form.addEventListener("change", () => this.autoSave())
    const editor = form.querySelector("trix-editor")
    if (editor) {
      editor.addEventListener("keydown", e => this.handleKey(e))
    }
  }

  focusEditor() {
    const editor = this.formTarget.querySelector("trix-editor")
    if (editor) editor.focus()
  }

  autoSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => {
      const form = this.formTarget.querySelector("form")
      if (!form) return
      fetch(this.updateUrlValue, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
          "Accept": "application/json"
        },
        body: new FormData(form),
        credentials: "same-origin"
      })
    }, 400)
  }

  handleKey(e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault()
      this.autoSave()
      this.moveToNext()
    } else if (e.key === "Enter" && e.shiftKey) {
      e.preventDefault()
      this.autoSave()
      this.addChild()
    }
  }

  moveToNext() {
    this.toggleVisibility()
    const next = this.element.nextElementSibling
    if (next) {
      const btn = next.querySelector('[data-action="inline-editor#showForm"]')
      if (btn) { btn.click(); return }
    }
    fetch('/creatives', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      },
      body: JSON.stringify({ creative: { description: 'New Creative', parent_id: this.siblingParentIdValue } })
    })
      .then(r => r.json())
      .then(data => {
        if (data.id) {
          window.location.href = `/creatives/${data.id}?edit=1`
        }
      })
  }

  addChild() {
    fetch('/creatives', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      },
      body: JSON.stringify({ creative: { description: 'New Creative', parent_id: this.parentIdValue } })
    })
      .then(r => r.json())
      .then(data => {
        if (data.id) {
          window.location.href = `/creatives/${data.id}?edit=1`
        }
      })
  }
}
