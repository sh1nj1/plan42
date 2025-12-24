const DEFAULT_EMOJIS = ["🌿", "🌱", "🍃", "🍀", "🌼", "🌸"]
const FRAME_SIZE = 3
const INTERVAL_MS = 550

function parseEmojiVariable(rawValue) {
  if (!rawValue) return []
  return rawValue
    .replace(/["']/g, "")
    .split(/[\s,]+/)
    .map((emoji) => emoji.trim())
    .filter(Boolean)
}

export function getThemeLoadingEmojis() {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return DEFAULT_EMOJIS
  }

  const rawValue = getComputedStyle(document.body).getPropertyValue("--creative-loading-emojis")
  const emojis = parseEmojiVariable(rawValue)

  return emojis.length > 0 ? emojis : DEFAULT_EMOJIS
}

export function buildEmojiFrames(emojis = [], frameSize = FRAME_SIZE) {
  if (!Array.isArray(emojis) || emojis.length === 0) return []

  const frames = []
  const size = Math.max(1, frameSize)

  emojis.forEach((_, index) => {
    const frame = []
    for (let step = 0; step < size; step += 1) {
      frame.push(emojis[(index + step) % emojis.length])
    }
    frames.push(frame.join(" "))
  })

  return frames
}

export class CreativeLoadingAnimator {
  constructor(symbolElement, { frameSize = FRAME_SIZE, intervalMs = INTERVAL_MS } = {}) {
    this.symbolElement = symbolElement
    this.intervalMs = intervalMs
    this.frameSize = frameSize
    this.frames = buildEmojiFrames(getThemeLoadingEmojis(), this.frameSize)
    if (this.frames.length === 0) this.frames = ["..."]

    this.frameIndex = 0
    this.timerId = null
  }

  start() {
    if (this.timerId || !this.symbolElement) return

    this.renderFrame()
    this.timerId = window.setInterval(() => this.renderFrame(), this.intervalMs)
  }

  renderFrame() {
    if (!this.symbolElement) return

    this.symbolElement.textContent = this.frames[this.frameIndex]
    this.frameIndex = (this.frameIndex + 1) % this.frames.length
  }

  stop() {
    if (!this.timerId) return

    window.clearInterval(this.timerId)
    this.timerId = null
  }
}

export function createCreativeLoadingIndicator({ label } = {}) {
  const container = document.createElement("span")
  container.className = "creative-loading-indicator"
  container.setAttribute("role", "status")
  container.setAttribute("aria-live", "polite")
  if (label) container.setAttribute("aria-label", label)

  const symbols = document.createElement("span")
  symbols.className = "creative-loading-symbols"
  symbols.setAttribute("aria-hidden", "true")
  container.appendChild(symbols)

  const animator = new CreativeLoadingAnimator(symbols)

  return { element: container, animator }
}
