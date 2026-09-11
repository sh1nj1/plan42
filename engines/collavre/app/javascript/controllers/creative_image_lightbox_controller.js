import ImageLightboxController from "./image_lightbox_controller"

// Delegate from the creative list so streamed rows and title images work too.
export default class extends ImageLightboxController {
  open(event) {
    const image = event.target.closest("img")
    const content = image?.closest(".creative-content, .creative-title-content")
    if (!content || image.closest('[contenteditable="true"], .inline-edit-form')) return
    if (content.closest("creative-tree-row")?.selectMode) return

    const images = Array.from(content.querySelectorAll("img[src]")).filter((img) => img.getAttribute("src"))
    const index = images.indexOf(image)
    if (index < 0) return

    event.preventDefault()
    event.stopPropagation()
    this._openImages(images.map((img) => ({ fullSrc: img.src, filename: img.alt })), index)
  }
}
