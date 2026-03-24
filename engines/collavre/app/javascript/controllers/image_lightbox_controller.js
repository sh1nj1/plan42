import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="image-lightbox"
// Provides a fullscreen image carousel with navigation, download, and zoom
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
    const iframe = document.createElement("iframe")
    iframe.style.cssText = "position:absolute;width:0;height:0;border:0;visibility:hidden"
    document.body.appendChild(iframe)
    iframe.src = url
    setTimeout(() => iframe.remove(), 30000)
  }

  // --- Zoom ---

  _resetZoom() {
    this._zoom = 1
    this._panX = 0
    this._panY = 0
    this._applyTransform()
  }

  _setZoom(newZoom, centerX, centerY) {
    const MIN = 0.5, MAX = 5
    const clamped = Math.min(MAX, Math.max(MIN, newZoom))
    if (clamped === this._zoom) return

    // Adjust pan so zoom centers on the pointer position
    if (centerX !== undefined && centerY !== undefined) {
      const imgEl = this._dialog.querySelector(".image-lightbox-image")
      const rect = imgEl.getBoundingClientRect()
      const ox = centerX - rect.left - rect.width / 2
      const oy = centerY - rect.top - rect.height / 2
      const ratio = 1 - clamped / this._zoom
      this._panX += ox * ratio
      this._panY += oy * ratio
    }

    this._zoom = clamped

    // Reset pan if back to fit
    if (this._zoom <= 1) {
      this._panX = 0
      this._panY = 0
    }

    this._applyTransform()
  }

  _applyTransform() {
    const imgEl = this._dialog?.querySelector(".image-lightbox-image")
    if (!imgEl) return
    imgEl.style.transform = `translate(${this._panX}px, ${this._panY}px) scale(${this._zoom})`
    imgEl.style.cursor = this._zoom > 1 ? "grab" : "default"
  }

  _setupZoom(dialog) {
    this._zoom = 1
    this._panX = 0
    this._panY = 0

    const stage = dialog.querySelector(".image-lightbox-stage")
    const imgEl = dialog.querySelector(".image-lightbox-image")

    // Mouse wheel zoom
    stage.addEventListener("wheel", (e) => {
      e.preventDefault()
      const delta = e.deltaY > 0 ? -0.15 : 0.15
      this._setZoom(this._zoom + delta, e.clientX, e.clientY)
    }, { passive: false })

    // Double-click to toggle zoom
    imgEl.addEventListener("dblclick", (e) => {
      e.stopPropagation()
      if (this._zoom > 1) {
        this._resetZoom()
      } else {
        this._setZoom(2.5, e.clientX, e.clientY)
      }
    })

    // Mouse drag to pan when zoomed
    let dragging = false, dragStartX = 0, dragStartY = 0, panStartX = 0, panStartY = 0

    imgEl.addEventListener("mousedown", (e) => {
      if (this._zoom <= 1) return
      e.preventDefault()
      dragging = true
      dragStartX = e.clientX
      dragStartY = e.clientY
      panStartX = this._panX
      panStartY = this._panY
      imgEl.style.cursor = "grabbing"
    })

    window.addEventListener("mousemove", this._onMouseMove = (e) => {
      if (!dragging) return
      this._panX = panStartX + (e.clientX - dragStartX)
      this._panY = panStartY + (e.clientY - dragStartY)
      this._applyTransform()
    })

    window.addEventListener("mouseup", this._onMouseUp = () => {
      if (!dragging) return
      dragging = false
      const imgEl2 = this._dialog?.querySelector(".image-lightbox-image")
      if (imgEl2) imgEl2.style.cursor = this._zoom > 1 ? "grab" : "default"
    })

    // Pinch zoom (touch)
    let lastPinchDist = 0

    stage.addEventListener("touchstart", (e) => {
      if (e.touches.length === 2) {
        lastPinchDist = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        )
      }
    }, { passive: true })

    stage.addEventListener("touchmove", (e) => {
      if (e.touches.length === 2) {
        e.preventDefault()
        const dist = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        )
        const centerX = (e.touches[0].clientX + e.touches[1].clientX) / 2
        const centerY = (e.touches[0].clientY + e.touches[1].clientY) / 2
        const scale = dist / lastPinchDist
        this._setZoom(this._zoom * scale, centerX, centerY)
        lastPinchDist = dist
      }
    }, { passive: false })
  }

  _cleanupZoom() {
    if (this._onMouseMove) window.removeEventListener("mousemove", this._onMouseMove)
    if (this._onMouseUp) window.removeEventListener("mouseup", this._onMouseUp)
  }

  _createDialog() {
    if (this._dialog) {
      this._cleanupZoom()
      this._dialog.remove()
    }

    const dialog = document.createElement("dialog")
    dialog.className = "image-lightbox-dialog"
    dialog.innerHTML = `
      <div class="image-lightbox-container">
        <div class="image-lightbox-toolbar">
          <span class="image-lightbox-counter"></span>
          <div class="image-lightbox-toolbar-actions">
            <button class="image-lightbox-btn image-lightbox-zoom-in" type="button" title="Zoom in">🔍+</button>
            <button class="image-lightbox-btn image-lightbox-zoom-out" type="button" title="Zoom out">🔍−</button>
            <button class="image-lightbox-btn image-lightbox-zoom-reset" type="button" title="Reset zoom">1:1</button>
            <button class="image-lightbox-btn image-lightbox-download-one" type="button" title="Download">⬇ Download</button>
            ${this.hasDownloadAllUrlValue ? `<button class="image-lightbox-btn image-lightbox-download-all" type="button" title="Download all">📥 All</button>` : ""}
            <button class="image-lightbox-btn image-lightbox-delete" type="button" title="Delete">🗑 Delete</button>
            <button class="image-lightbox-btn image-lightbox-close" type="button" title="Close">✕ Close</button>
          </div>
        </div>
        <div class="image-lightbox-stage">
          <button class="image-lightbox-nav image-lightbox-prev" type="button" title="Previous">‹</button>
          <img class="image-lightbox-image" src="" alt="" draggable="false" />
          <button class="image-lightbox-nav image-lightbox-next" type="button" title="Next">›</button>
        </div>
      </div>
    `

    // Close on backdrop click
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

    // Zoom buttons
    dialog.querySelector(".image-lightbox-zoom-in").addEventListener("click", (e) => {
      e.stopPropagation()
      this._setZoom(this._zoom + 0.25)
    })
    dialog.querySelector(".image-lightbox-zoom-out").addEventListener("click", (e) => {
      e.stopPropagation()
      this._setZoom(this._zoom - 0.25)
    })
    dialog.querySelector(".image-lightbox-zoom-reset").addEventListener("click", (e) => {
      e.stopPropagation()
      this._resetZoom()
    })

    // Delete button
    dialog.querySelector(".image-lightbox-delete").addEventListener("click", async (e) => {
      e.stopPropagation()
      if (!this.hasDownloadAllUrlValue) return
      if (!confirm("Delete this image?")) return

      const url = `${this.downloadAllUrlValue.replace("download_images", "remove_image")}?index=${this._currentIndex}`
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

      try {
        const resp = await fetch(url, {
          method: "DELETE",
          credentials: "same-origin",
          headers: { "X-CSRF-Token": csrfToken }
        })
        if (resp.ok) {
          // Remove from gallery
          this._images.splice(this._currentIndex, 1)
          if (this._images.length === 0) {
            this._close()
            // Reload comments to reflect removal
            this.element.closest("[data-controller]")?.dispatchEvent(new CustomEvent("lightbox:image-deleted", { bubbles: true }))
            location.reload()
            return
          }
          if (this._currentIndex >= this._images.length) {
            this._currentIndex = this._images.length - 1
          }
          this._showImage()

          // Update download-all visibility
          const downloadAllBtn = this._dialog.querySelector(".image-lightbox-download-all")
          if (downloadAllBtn && this._images.length <= 1) {
            downloadAllBtn.style.display = "none"
          }
        }
      } catch (err) {
        console.error("Delete failed:", err)
      }
    })

    // Download buttons
    dialog.querySelector(".image-lightbox-download-one").addEventListener("click", (e) => {
      e.stopPropagation()
      if (!this.hasDownloadAllUrlValue) return
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

    // Touch swipe (only when not zoomed)
    let touchStartX = 0
    const stage = dialog.querySelector(".image-lightbox-stage")
    stage.addEventListener("touchstart", (e) => {
      if (e.touches.length === 1) touchStartX = e.changedTouches[0].screenX
    }, { passive: true })
    stage.addEventListener("touchend", (e) => {
      if (this._zoom > 1) return // Don't swipe when zoomed
      if (e.changedTouches.length === 1) {
        const diff = e.changedTouches[0].screenX - touchStartX
        if (Math.abs(diff) > 50) {
          diff > 0 ? this._prev() : this._next()
        }
      }
    }, { passive: true })

    // Setup zoom interactions (wheel, pinch, drag)
    this._setupZoom(dialog)

    document.body.appendChild(dialog)
    this._dialog = dialog
  }

  _showImage() {
    if (!this._dialog || !this._images.length) return

    const img = this._images[this._currentIndex]
    const imgEl = this._dialog.querySelector(".image-lightbox-image")
    imgEl.src = img.fullSrc

    // Reset zoom on image change
    this._resetZoom()

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
    this._cleanupZoom()
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
      case "+":
      case "=":
        e.preventDefault()
        this._setZoom(this._zoom + 0.25)
        break
      case "-":
        e.preventDefault()
        this._setZoom(this._zoom - 0.25)
        break
      case "0":
        e.preventDefault()
        this._resetZoom()
        break
    }
  }
}
