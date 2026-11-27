import ImageLightboxController from "./image_lightbox_controller"

export default class extends ImageLightboxController {
  open(event) {
    const imageSelector = 'img[src]:not([src=""])'
    const image = event.target.closest(imageSelector)
    const content = image?.closest(".comment-content")
    if (!content) return

    const images = Array.from(content.querySelectorAll(imageSelector))
    event.preventDefault()
    event.stopPropagation()
    this._openImages(images.map((img) => ({ fullSrc: img.src, alt: img.alt })), images.indexOf(image))
  }
}
