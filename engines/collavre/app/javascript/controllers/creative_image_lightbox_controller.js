import ImageLightboxController from "./image_lightbox_controller"

// Delegate from the creative list so streamed rows and title images work too.
export default class extends ImageLightboxController {
  static values = { ...ImageLightboxController.values, i18nOpen: String }

  connect() {
    super.connect()
    this._generatedLinkLabels ||= new WeakMap()
    this._prepareImages()
    this._imageObserver = new MutationObserver(() => this._prepareImages())
    this._imageObserver.observe(this.element, {
      childList: true, subtree: true, attributes: true, attributeFilter: ["src", "alt"]
    })
  }

  disconnect() {
    this._imageObserver.disconnect()
    super.disconnect()
  }

  _prepareImages() {
    this._listImages().forEach((image) => {
      const link = image.closest("a[href]")
      if (link) {
        this._prepareLink(link)
        return
      }
      image.tabIndex = 0
      image.setAttribute("role", "button")
      image.setAttribute("aria-haspopup", "dialog")
      image.setAttribute("aria-label", image.alt || this.i18nOpenValue)
    })
  }

  _listImages() {
    return Array.from(this.element.querySelectorAll('.creative-content img[src], .creative-title-content img[src]'))
      .filter((image) => image.getAttribute("src") && !image.closest('[contenteditable="true"], .inline-edit-form-shell'))
  }

  _hiddenInList(image) {
    for (let element = image; element && element !== this.element; element = element.parentElement) {
      if (element.hidden || element.style.display === "none") return true
    }
    return false
  }

  _prepareLink(link) {
    this._clearGeneratedLinkLabel(link)
    if (link.textContent.trim()) {
      link.removeAttribute("aria-haspopup")
      return
    }
    link.setAttribute("aria-haspopup", "dialog")
    const named = ["aria-label", "aria-labelledby", "title"].some((name) => link.getAttribute(name)?.trim()) ||
      Array.from(link.querySelectorAll("img")).some((image) => image.alt.trim())
    if (!named) {
      link.setAttribute("aria-label", this.i18nOpenValue)
      this._generatedLinkLabels.set(link, this.i18nOpenValue)
    }
  }

  _clearGeneratedLinkLabel(link) {
    // Recompute only our fallback; preserve names supplied by the content author.
    if (link.getAttribute("aria-label") === this._generatedLinkLabels.get(link)) {
      link.removeAttribute("aria-label")
    }
    this._generatedLinkLabels.delete(link)
  }

  openFromKeyboard(event) {
    if (event.key === "Enter" || event.key === " ") this.open(event)
  }

  _imageForEvent(event) {
    const image = event.target.closest("img")
    if (image) return image
    // Native keyboard/assistive-technology clicks target the link, not its image.
    if (event.detail !== 0) return null
    const link = event.target.closest("a")
    // Mixed text/image links retain keyboard navigation to their destination.
    return link && !link.textContent.trim() ? link.querySelector('img[src]:not([src=""])') : null
  }

  open(event) {
    const image = this._imageForEvent(event)
    const content = image?.closest(".creative-content, .creative-title-content")
    if (!content || image.closest('[contenteditable="true"], .inline-edit-form-shell')) return
    if (this._selectionActive(content)) {
      if (event.type === "keydown") {
        // Suppress document shortcuts while preserving pointer row selection.
        event.preventDefault()
        event.stopPropagation()
      } else if (image.closest("a")) event.preventDefault()
      return
    }

    // Keep hidden images prepared for keyboard access when their rows are revealed.
    const images = this._listImages().filter((image) => !this._hiddenInList(image))
    const index = images.indexOf(image)
    if (index < 0) return

    event.preventDefault()
    event.stopPropagation()
    this._openImages(images.map((img) => ({ fullSrc: img.src, alt: img.alt })), index)
  }

  _selectionActive(content) {
    if (content.closest("creative-tree-row")?.selectMode) return true

    const scope = content.closest('[data-controller~="creatives--select-mode"]')
    return scope && this.application.getControllerForElementAndIdentifier(scope, "creatives--select-mode")?.active
  }
}
