import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "previewContainer", "previewImage", "placeholder"]

  connect() {
    this.previewUrl = null
  }

  disconnect() {
    this.revokePreview()
  }

  update() {
    const [file] = this.inputTarget.files

    this.revokePreview()

    if (!file) {
      this.showPlaceholder()
      return
    }

    const previewUrl = URL.createObjectURL(file)
    this.previewUrl = previewUrl

    this.previewImageTarget.src = previewUrl
    this.previewImageTarget.alt = file.name
    this.previewImageTarget.classList.remove("avatar-preview-hidden")
    this.placeholderTarget.classList.add("avatar-preview-hidden")
    this.previewContainerTarget.classList.add("avatar-preview-visible")
  }

  showPlaceholder() {
    this.previewImageTarget.classList.add("avatar-preview-hidden")
    this.previewImageTarget.removeAttribute("src")
    this.placeholderTarget.classList.remove("avatar-preview-hidden")
    this.previewContainerTarget.classList.remove("avatar-preview-visible")
  }

  revokePreview() {
    if (this.previewUrl) {
      URL.revokeObjectURL(this.previewUrl)
      this.previewUrl = null
    }
  }
}
