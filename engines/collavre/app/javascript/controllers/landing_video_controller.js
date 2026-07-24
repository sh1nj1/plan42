import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["video", "progressBar", "progressFill", "toggle", "icon"]

  connect() {
    this._raf = null
    this._updateProgress = this._updateProgress.bind(this)
    this.videoTarget.addEventListener("play", () => this._startProgress())
    this.videoTarget.addEventListener("pause", () => this._stopProgress())
    this.videoTarget.addEventListener("ended", () => this._stopProgress())
    if (!this.videoTarget.paused) this._startProgress()
  }

  disconnect() {
    this._stopProgress()
  }

  togglePlay() {
    if (this.videoTarget.paused) {
      this.videoTarget.play()
      this.iconTarget.textContent = "❚❚"
    } else {
      this.videoTarget.pause()
      this.iconTarget.textContent = "▶"
    }
  }

  _startProgress() {
    this._stopProgress()
    this._tick()
  }

  _stopProgress() {
    if (this._raf) {
      cancelAnimationFrame(this._raf)
      this._raf = null
    }
  }

  _tick() {
    this._updateProgress()
    this._raf = requestAnimationFrame(() => this._tick())
  }

  _updateProgress() {
    const v = this.videoTarget
    if (v.duration) {
      const pct = (v.currentTime / v.duration) * 100
      this.progressFillTarget.style.width = `${pct}%`
    }
  }
}
