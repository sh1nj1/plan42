import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="image-lightbox"
// Provides a fullscreen image carousel with navigation and download
export default class extends Controller {
  static values = {
    downloadAllUrl: String
  }

  connect() {
    this._boundKeydown = this._handleKeydown.bind(this)
  }

  disconnect() {
    this._close()
  }

  open(event) {
    event.preventDefault()
    event.stopPropagation()

    const link = event.currentTarget
    this._images = this._collectImages()
    this._currentIndex = parseInt(link.dataset.imageLightboxIndexParam, 10) || 0

    this._createDialog()
    this._showImage()
    this._dialog.showModal()
    document.addEventListener("keydown", this._boundKeydown)
  }

  // --- Private ---

  _collectImages() {
    const links = this.element.querySelectorAll("[data-full-src]")
    return Array.from(links).map((link) => ({
      fullSrc: link.dataset.fullSrc,
      downloadSrc: link.dataset.downloadSrc,
      filename: link.dataset.filename || ""
    }))
  }

  _createDialog() {
    if (this._dialog) {
      this._dialog.remove()
    }

    const dialog = document.createElement("dialog")
    dialog.className = "image-lightbox-dialog"
    dialog.innerHTML = `
      <div class="image-lightbox-backdrop" data-action="click"></div>
      <div class="image-lightbox-container">
        <div class="image-lightbox-toolbar">
          <span class="image-lightbox-counter"></span>
          <div class="image-lightbox-toolbar-actions">
            <a class="image-lightbox-btn image-lightbox-download-one" title="" download data-turbo="false">⬇</a>
            ${this.hasDownloadAllUrlValue ? `<a class="image-lightbox-btn image-lightbox-download-all" href="${this.downloadAllUrlValue}" title="" data-turbo="false">📥</a>` : ""}
            <button class="image-lightbox-btn image-lightbox-close" type="button" title="">✕</button>
          </div>
        </div>
        <div class="image-lightbox-stage">
          <button class="image-lightbox-nav image-lightbox-prev" type="button" title="">‹</button>
          <img class="image-lightbox-image" src="" alt="" />
          <button class="image-lightbox-nav image-lightbox-next" type="button" title="">›</button>
        </div>
      </div>
    `

    // Event listeners
    dialog.querySelector(".image-lightbox-backdrop").addEventListener("click", () => this._close())
    dialog.querySelector(".image-lightbox-close").addEventListener("click", () => this._close())
    dialog.querySelector(".image-lightbox-prev").addEventListener("click", () => this._prev())
    dialog.querySelector(".image-lightbox-next").addEventListener("click", () => this._next())
    dialog.addEventListener("cancel", (e) => {
      e.preventDefault()
      this._close()
    })

    // Handle download links - use programmatic download to avoid dialog interference
    dialog.querySelectorAll(".image-lightbox-download-one, .image-lightbox-download-all").forEach((el) => {
      el.addEventListener("click", (e) => {
        e.preventDefault()
        e.stopPropagation()
        const url = el.href
        if (!url) return
        // Create a temporary link outside the dialog to trigger download
        const tmpLink = document.createElement("a")
        tmpLink.href = url
        tmpLink.download = el.download || ""
        tmpLink.setAttribute("data-turbo", "false")
        tmpLink.style.display = "none"
        document.body.appendChild(tmpLink)
        tmpLink.click()
        document.body.removeChild(tmpLink)
      })
    })

    // Touch swipe
    let touchStartX = 0
    const stage = dialog.querySelector(".image-lightbox-stage")
    stage.addEventListener("touchstart", (e) => {
      touchStartX = e.changedTouches[0].screenX
    }, { passive: true })
    stage.addEventListener("touchend", (e) => {
      const diff = e.changedTouches[0].screenX - touchStartX
      if (Math.abs(diff) > 50) {
        diff > 0 ? this._prev() : this._next()
      }
    }, { passive: true })

    document.body.appendChild(dialog)
    this._dialog = dialog
  }

  _showImage() {
    if (!this._dialog || !this._images.length) return

    const img = this._images[this._currentIndex]
    const imgEl = this._dialog.querySelector(".image-lightbox-image")
    imgEl.src = img.fullSrc

    // Counter
    const counter = this._dialog.querySelector(".image-lightbox-counter")
    counter.textContent = `${this._currentIndex + 1} / ${this._images.length}`

    // Download link
    const downloadBtn = this._dialog.querySelector(".image-lightbox-download-one")
    downloadBtn.href = img.downloadSrc

    // Nav visibility
    const prevBtn = this._dialog.querySelector(".image-lightbox-prev")
    const nextBtn = this._dialog.querySelector(".image-lightbox-next")
    prevBtn.style.visibility = this._images.length > 1 ? "visible" : "hidden"
    nextBtn.style.visibility = this._images.length > 1 ? "visible" : "hidden"
  }

  _prev() {
    if (this._images.length <= 1) return
    this._currentIndex = (this._currentIndex - 1 + this._images.length) % this._images.length
    this._showImage()
  }

  _next() {
    if (this._images.length <= 1) return
    this._currentIndex = (this._currentIndex + 1) % this._images.length
    this._showImage()
  }

  _close() {
    document.removeEventListener("keydown", this._boundKeydown)
    if (this._dialog) {
      this._dialog.close()
      this._dialog.remove()
      this._dialog = null
    }
  }

  _handleKeydown(e) {
    switch (e.key) {
      case "ArrowLeft":
        e.preventDefault()
        this._prev()
        break
      case "ArrowRight":
        e.preventDefault()
        this._next()
        break
      case "Escape":
        e.preventDefault()
        this._close()
        break
    }
  }
}
