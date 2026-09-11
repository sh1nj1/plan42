import ImageLightboxController from "./image_lightbox_controller"

// Delegate from the creative list so streamed rows and title images work too.
export default class extends ImageLightboxController {
  open(event) {
    const image = event.target.closest("img")
    const content = image?.closest(".creative-content, .creative-title-content")
    if (!content || image.closest('[contenteditable="true"], .inline-edit-form')) return
    if (this._selectionActive(content)) {
      if (image.closest("a")) event.preventDefault()
      return
    }

    const images = Array.from(content.querySelectorAll("img[src]")).filter((img) => img.getAttribute("src"))
    const index = images.indexOf(image)
    if (index < 0) return

    event.preventDefault()
    event.stopPropagation()
    this._openImages(images.map((img) => ({ fullSrc: img.src, filename: img.alt })), index)
  }

  _selectionActive(content) {
    if (content.closest("creative-tree-row")?.selectMode) return true

    const scope = content.closest('[data-controller~="creatives--select-mode"]')
    return scope && this.application.getControllerForElementAndIdentifier(scope, "creatives--select-mode")?.active
  }
}
