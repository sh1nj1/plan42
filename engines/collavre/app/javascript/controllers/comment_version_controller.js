import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["prevBtn", "nextBtn", "indicator", "deleteBtn", "selectBtn"]
  static values = {
    commentId: Number,
    creativeId: Number,
    total: Number,
    contentTarget: String,
    versionsUrl: String,
    selectedVersionId: Number
  }

  connect() {
    this.versions = null
    this.currentIndex = this.totalValue // default: latest (current content)
    this.updateButtons()
  }

  async fetchVersions() {
    if (this.versions) return this.versions

    const response = await fetch(
      this.versionsUrlValue,
      { headers: { "Accept": "application/json" } }
    )
    const data = await response.json()
    this.versions = data.versions
    this.currentContent = data.current_content
    this.selectedVersionId = data.selected_version_id
    this.totalValue = data.total

    // Set currentIndex based on selected version
    if (this.selectedVersionId) {
      const idx = this.versions.findIndex(v => v.id === this.selectedVersionId)
      if (idx !== -1) this.currentIndex = idx + 1
    } else {
      this.currentIndex = this.totalValue
    }

    return this.versions
  }

  async prev() {
    if (this.currentIndex <= 1) return
    await this.fetchVersions()
    this.currentIndex--
    this.render()
  }

  async next() {
    if (this.currentIndex >= this.totalValue) return
    await this.fetchVersions()
    this.currentIndex++
    this.render()
  }

  async selectVersion() {
    const versions = await this.fetchVersions()

    if (this.currentIndex === this.totalValue) {
      // Selecting "current" = deselect (clear pointer)
      const response = await fetch(
        `${this.versionsUrlValue}/deselect`,
        { method: "POST", headers: { "X-CSRF-Token": this.csrfToken } }
      )
      if (response.ok) {
        this.selectedVersionId = null
        this.updateButtons()
      }
      return
    }

    const version = versions[this.currentIndex - 1]
    if (!version) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}/select`,
      { method: "POST", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      this.selectedVersionId = version.id
      this.updateButtons()
    }
  }

  async deleteVersion() {
    if (this.currentIndex === this.totalValue) return

    const versions = await this.fetchVersions()
    const version = versions[this.currentIndex - 1]
    if (!version) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}`,
      { method: "DELETE", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      // If deleting the selected version, clear selection
      if (this.selectedVersionId === version.id) {
        this.selectedVersionId = null
      }

      versions.splice(this.currentIndex - 1, 1)
      this.totalValue = versions.length + 1
      if (this.currentIndex > this.totalValue) {
        this.currentIndex = this.totalValue
      }
      this.render()

      if (versions.length === 0) {
        // Show current content and remove navigator
        this.setContentText(this.currentContent)
        this.element.remove()
      }
    }
  }

  render() {
    if (this.currentIndex === this.totalValue) {
      this.setContentText(this.currentContent)
    } else {
      const version = this.versions[this.currentIndex - 1]
      if (version) this.setContentText(version.content)
    }

    this.indicatorTarget.textContent = `v${this.currentIndex}/${this.totalValue}`
    this.updateButtons()
  }

  setContentText(text) {
    const el = document.getElementById(this.contentTargetValue)
    const target = el?.querySelector(".comment-content") || el?.querySelector("[data-comment-target='content']")
    if (target) target.textContent = text
  }

  updateButtons() {
    this.prevBtnTarget.disabled = this.currentIndex <= 1
    this.nextBtnTarget.disabled = this.currentIndex >= this.totalValue

    const isHistorical = this.currentIndex < this.totalValue
    const isCurrentlySelected = this.isSelectedIndex()

    // Delete: only for historical versions
    if (this.hasDeleteBtnTarget) {
      this.deleteBtnTarget.classList.toggle("comment-version-delete-hidden", !isHistorical)
    }

    // Select: show for historical versions, disable if already selected
    if (this.hasSelectBtnTarget) {
      this.selectBtnTarget.classList.toggle("comment-version-delete-hidden", !isHistorical)
      this.selectBtnTarget.disabled = isCurrentlySelected
    }

    // Highlight the indicator if viewing the selected version
    this.indicatorTarget.classList.toggle("comment-version-selected", isCurrentlySelected && isHistorical)
  }

  isSelectedIndex() {
    if (!this.selectedVersionId) return this.currentIndex === this.totalValue
    if (this.currentIndex === this.totalValue) return !this.selectedVersionId
    if (!this.versions) return false
    const version = this.versions[this.currentIndex - 1]
    return version && version.id === this.selectedVersionId
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
