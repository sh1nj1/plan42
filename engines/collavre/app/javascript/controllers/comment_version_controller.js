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
    this.currentIndex = this.totalValue
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
      // Selecting latest = deselect (clear pointer)
      const response = await fetch(
        `${this.versionsUrlValue}/deselect`,
        { method: "POST", headers: { "X-CSRF-Token": this.csrfToken } }
      )
      if (response.ok) {
        const data = await response.json()
        this.selectedVersionId = null
        this.currentContent = data.content
        this.render()
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
      this.currentContent = version.content
      this.render()
    }
  }

  async deleteVersion() {
    const versions = await this.fetchVersions()

    if (this.currentIndex === this.totalValue) {
      // Deleting "latest" (comment.content that's not in versions) — not allowed
      // This slot represents the latest AI output, only version records can be deleted
      return
    }

    const version = versions[this.currentIndex - 1]
    if (!version) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}`,
      { method: "DELETE", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      const data = await response.json()
      versions.splice(this.currentIndex - 1, 1)
      this.totalValue = data.total
      this.selectedVersionId = data.selected_version_id
      this.currentContent = data.content

      if (this.currentIndex > this.totalValue) {
        this.currentIndex = this.totalValue
      }

      // If the deleted version was selected, jump to the new selection
      if (data.selected_version_id) {
        const idx = versions.findIndex(v => v.id === data.selected_version_id)
        if (idx !== -1) this.currentIndex = idx + 1
      }

      this.render()

      if (versions.length === 0) {
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

    const isLatestSlot = this.currentIndex === this.totalValue
    const isCurrentlySelected = this.isSelectedIndex()

    // Delete: always visible, disabled for latest slot (not a version record)
    if (this.hasDeleteBtnTarget) {
      this.deleteBtnTarget.disabled = isLatestSlot
    }

    // Select: always visible, disabled if already selected
    if (this.hasSelectBtnTarget) {
      this.selectBtnTarget.disabled = isCurrentlySelected
    }

    // Highlight indicator when viewing the selected/active version
    this.indicatorTarget.classList.toggle("comment-version-selected", isCurrentlySelected)
  }

  isSelectedIndex() {
    if (!this.selectedVersionId) return this.currentIndex === this.totalValue
    if (!this.versions) return false
    if (this.currentIndex === this.totalValue) return !this.selectedVersionId
    const version = this.versions[this.currentIndex - 1]
    return version && version.id === this.selectedVersionId
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
