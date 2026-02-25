import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["prevBtn", "nextBtn", "indicator", "deleteBtn", "selectBtn"]
  static values = {
    commentId: Number,
    creativeId: Number,
    total: Number,
    contentTarget: String,
    versionsUrl: String
  }

  connect() {
    this.currentIndex = this.totalValue // 1-based, starts at latest (current)
    this.versions = null
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
    this.totalValue = data.total
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
    if (this.currentIndex === this.totalValue) return // already current

    const versions = await this.fetchVersions()
    const version = versions[this.currentIndex - 1]
    if (!version) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}/select`,
      { method: "POST", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      const data = await response.json()
      // Reset: refetch versions on next navigation
      this.versions = null
      this.currentContent = data.content
      this.totalValue = data.total
      this.currentIndex = this.totalValue
      this.render()
    }
  }

  async deleteVersion() {
    if (this.currentIndex === this.totalValue) return // can't delete current

    const versions = await this.fetchVersions()
    const version = versions[this.currentIndex - 1]
    if (!version) return

    const response = await fetch(
      `${this.versionsUrlValue}/${version.id}`,
      { method: "DELETE", headers: { "X-CSRF-Token": this.csrfToken } }
    )

    if (response.ok) {
      versions.splice(this.currentIndex - 1, 1)
      this.totalValue = versions.length + 1
      if (this.currentIndex > this.totalValue) {
        this.currentIndex = this.totalValue
      }
      this.render()

      // Remove navigator if no versions left
      if (versions.length === 0) {
        this.element.remove()
      }
    }
  }

  render() {
    const contentEl = document.getElementById(this.contentTargetValue)
      ?.querySelector(".comment-content, [data-comment-target='content']")
      || document.getElementById(this.contentTargetValue)
        ?.querySelector(".comment-content")

    const target = contentEl || document.querySelector(
      `#${this.contentTargetValue} [data-comment-target="content"]`
    )

    if (target) {
      if (this.currentIndex === this.totalValue) {
        target.textContent = this.currentContent
      } else {
        const version = this.versions[this.currentIndex - 1]
        if (version) target.textContent = version.content
      }
    }

    this.indicatorTarget.textContent = `v${this.currentIndex}/${this.totalValue}`
    this.updateButtons()
  }

  updateButtons() {
    this.prevBtnTarget.disabled = this.currentIndex <= 1
    this.nextBtnTarget.disabled = this.currentIndex >= this.totalValue

    // Show delete/select buttons only for historical versions (not current)
    const isHistorical = this.currentIndex < this.totalValue
    if (this.hasDeleteBtnTarget) {
      this.deleteBtnTarget.classList.toggle("comment-version-delete-hidden", !isHistorical)
    }
    if (this.hasSelectBtnTarget) {
      this.selectBtnTarget.classList.toggle("comment-version-delete-hidden", !isHistorical)
    }
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
