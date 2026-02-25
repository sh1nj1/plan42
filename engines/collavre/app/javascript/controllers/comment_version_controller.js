import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["prevBtn", "nextBtn", "indicator", "deleteBtn", "selectBtn"]
  static values = {
    commentId: Number,
    creativeId: Number,
    total: Number,
    contentTarget: String,
    versionsUrl: String,
    selectedVersionId: Number,
    initialIndex: Number
  }

  connect() {
    this.versions = null
    this.currentIndex = this.initialIndexValue || this.totalValue
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
    const version = versions[this.currentIndex - 1]
    if (!version || version.id === this.selectedVersionId) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}/select`,
      { method: "POST", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      this.selectedVersionId = version.id
      this.render()
    }
  }

  async deleteVersion() {
    const versions = await this.fetchVersions()
    const version = versions[this.currentIndex - 1]
    if (!version) return

    // Can't delete if it's the only version
    if (versions.length <= 1) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}`,
      { method: "DELETE", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      const data = await response.json()
      versions.splice(this.currentIndex - 1, 1)
      this.totalValue = data.total
      this.selectedVersionId = data.selected_version_id

      if (this.currentIndex > this.totalValue) {
        this.currentIndex = this.totalValue
      }

      // Jump to newly selected version if changed
      if (data.selected_version_id) {
        const idx = versions.findIndex(v => v.id === data.selected_version_id)
        if (idx !== -1) this.currentIndex = idx + 1
      }

      this.render()

      if (versions.length <= 1) {
        // Only one version left — no need for navigator
        this.setContentText(versions[0]?.content || data.content)
        this.element.remove()
      }
    }
  }

  render() {
    const version = this.versions[this.currentIndex - 1]
    if (version) this.setContentText(version.content)

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

    const isCurrentlySelected = this.isSelectedIndex()
    const isOnlyVersion = this.totalValue <= 1

    // Delete: disabled if it's the selected version or the only version
    if (this.hasDeleteBtnTarget) {
      this.deleteBtnTarget.disabled = isCurrentlySelected || isOnlyVersion
    }

    // Select: disabled if already selected
    if (this.hasSelectBtnTarget) {
      this.selectBtnTarget.disabled = isCurrentlySelected
    }

    // Highlight indicator when viewing the selected version
    this.indicatorTarget.classList.toggle("comment-version-selected", isCurrentlySelected)
  }

  isSelectedIndex() {
    if (!this.versions) return this.currentIndex === this.totalValue
    const version = this.versions[this.currentIndex - 1]
    return version && version.id === this.selectedVersionId
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
