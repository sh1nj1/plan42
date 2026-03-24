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

  _triggerDownload(url) {
    if (!url) return
    // Use a hidden iframe appended to document.body (outside dialog)
    // This triggers a normal browser request with cookies, and
    // Content-Disposition: attachment causes a file download
    const iframe = document.createElement("iframe")
    iframe.style.cssText = "position:absolute;width:0;height:0;border:0;visibility:hidden"
    document.body.appendChild(iframe)
    iframe.src = url
    // Clean up after download starts
    setTimeout(() => iframe.remove(), 30000)
  }

  _createDialog() {
    if (this._dialog) {
      this._dialog.remove()
    }

    const dialog = document.createElement("dialog")
    dialog.className = "image-lightbox-dialog"
    dialog.innerHTML = `
      <div class="image-lightbox-container">
        <div class="image-lightbox-toolbar">
          <span class="image-lightbox-counter"></span>
          <div class="image-lightbox-toolbar-actions">
            <button class="image-lightbox-btn image-lightbox-download-one" type="button" title="Download">⬇</button>
            ${this.hasDownloadAllUrlValue ? `<button class="image-lightbox-btn image-lightbox-download-all" type="button" title="Download all">📥</button>` : ""}
            <button class="image-lightbox-btn image-lightbox-close" type="button" title="Close">✕</button>
          </div>
        </div>
        <div class="image-lightbox-stage">
          <button class="image-lightbox-nav image-lightbox-prev" type="button" title="Previous">‹</button>
          <img class="image-lightbox-image" src="" alt="" />
          <button class="image-lightbox-nav image-lightbox-next" type="button" title="Next">›</button>
        </div>
      </div>
    `

    // Close on backdrop click (clicking the dialog element itself, not children)
    dialog.addEventListener("click", (e) => {
      if (e.target === dialog) this._close()
    })
    dialog.querySelector(".image-lightbox-close").addEventListener("click", () => this._close())
    dialog.querySelector(".image-lightbox-prev").addEventListener("click", () => this._prev())
    dialog.querySelector(".image-lightbox-next").addEventListener("click", () => this._next())
    dialog.addEventListener("cancel", (e) => {
      e.preventDefault()
      this._close()
    })

    // Download buttons - use <button> not <a> to avoid all link/Turbo issues
    dialog.querySelector(".image-lightbox-download-one").addEventListener("click", (e) => {
      e.stopPropagation()
      if (!this.hasDownloadAllUrlValue) return
      // Use same-origin endpoint with index param to avoid CORS/CSP issues
      const url = `${this.downloadAllUrlValue}?index=${this._currentIndex}`
      this._triggerDownload(url)
    })

    const downloadAllBtn = dialog.querySelector(".image-lightbox-download-all")
    if (downloadAllBtn) {
      downloadAllBtn.addEventListener("click", (e) => {
        e.stopPropagation()
        this._triggerDownload(this.downloadAllUrlValue)
      })
    }

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
