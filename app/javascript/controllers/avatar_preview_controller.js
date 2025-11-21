import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "urlInput", "previewContainer", "previewImage"]

  connect() {
    this.defaultAlt = this.previewImageTarget.alt
    this.objectPreviewUrl = null
  }

  disconnect() {
    this.revokeObjectPreview()
  }

  update() {
    const [file] = this.inputTarget.files

    if (!file) {
      this.renderUrlPreviewIfPresent()
      return
    }

    this.revokeObjectPreview()
    const previewUrl = URL.createObjectURL(file)
    this.objectPreviewUrl = previewUrl

    this.setPreview(previewUrl, file.name)
  }

  updateFromUrl() {
    if (this.inputTarget.files.length > 0) return

    this.renderUrlPreviewIfPresent()
  }

  renderUrlPreviewIfPresent() {
    const url = this.hasUrlInputTarget ? this.urlInputTarget.value.trim() : ""

    if (url === "") {
      this.hidePreview()
      return
    }

    this.revokeObjectPreview()
    this.setPreview(url, url)
  }

  setPreview(src, altText) {
    this.previewImageTarget.src = src
    this.previewImageTarget.alt = altText || this.defaultAlt
    this.previewImageTarget.classList.remove("avatar-preview-hidden")
    this.previewContainerTarget.classList.add("avatar-preview-visible")
  }

  hidePreview() {
    this.previewImageTarget.classList.add("avatar-preview-hidden")
    this.previewImageTarget.removeAttribute("src")
    this.previewContainerTarget.classList.remove("avatar-preview-visible")
    this.revokeObjectPreview()
  }

  revokeObjectPreview() {
    if (this.objectPreviewUrl) {
      URL.revokeObjectURL(this.objectPreviewUrl)
      this.objectPreviewUrl = null
    }
  }
}
