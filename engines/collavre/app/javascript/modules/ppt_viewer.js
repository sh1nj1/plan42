function sizePreviewFrame(viewer) {
  const frame = viewer.ownerDocument.defaultView.frameElement
  const slide = viewer.querySelector('.ppt-slide')
  if (!frame || !slide) return
  const width = Number(slide.dataset.pptWidth)
  const height = Number(slide.dataset.pptHeight)
  const valid = value => Number.isFinite(value) && value >= 1 && value <= 1e9
  if (valid(width) && valid(height)) frame.style.aspectRatio = `${width} / ${height}`
}

function initializePresentationControls(viewer, fullscreen) {
  const doc = viewer.ownerDocument
  const touch = () => doc.defaultView.matchMedia('(hover: none)').matches
  fullscreen.hidden = typeof viewer.requestFullscreen !== 'function'
  async function toggleFullscreen() {
    const error = viewer.querySelector('[data-ppt-error]')
    error.hidden = true
    try {
      if (doc.fullscreenElement) await doc.exitFullscreen()
      else await viewer.requestFullscreen()
      viewer.focus()
    } catch {
      error.hidden = false
    }
  }
  fullscreen.addEventListener('click', toggleFullscreen)
  viewer.querySelector('[data-ppt-close]').addEventListener('click', toggleFullscreen)
  viewer.addEventListener('click', event => {
    if (event.target.closest('button, a')) return
    if (touch() || doc.fullscreenElement === viewer) viewer.classList.toggle('ppt-controls-visible')
    else if (!doc.fullscreenElement && !fullscreen.hidden) toggleFullscreen()
  })
  viewer.addEventListener('keydown', event => {
    if (event.key === 'Escape' && doc.fullscreenElement) toggleFullscreen()
    if (event.target !== viewer || !['Enter', ' '].includes(event.key)) return
    event.preventDefault()
    if (!fullscreen.hidden) toggleFullscreen()
  })
  doc.addEventListener('fullscreenchange', () => {
    viewer.classList.remove('ppt-controls-visible')
  })
}

export function initializePptViewer(viewer) {
  sizePreviewFrame(viewer)
  viewer.querySelectorAll(".ppt-viewer-slide a[href]").forEach(link => {
    link.target = "_blank"
    link.rel = "noopener noreferrer"
  })
  const slides = Array.from(viewer.querySelectorAll('.ppt-viewer-slide'))
  const previous = viewer.querySelector('[data-ppt-previous]')
  const next = viewer.querySelector('[data-ppt-next]')
  let index = 0
  function show(value) {
    index = Math.max(0, Math.min(value, slides.length - 1))
    slides.forEach((slide, position) => { slide.hidden = position !== index })
    previous.disabled = index === 0
    next.disabled = index === slides.length - 1
    viewer.querySelector('[data-ppt-counter]').textContent = `${index + 1} / ${slides.length}`
  }
  previous.addEventListener('click', () => show(index - 1))
  next.addEventListener('click', () => show(index + 1))
  viewer.ownerDocument.addEventListener('keydown', event => {
    if (!viewer.isConnected) return
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return
    event.preventDefault()
    show(index + (event.key === 'ArrowRight' ? 1 : -1))
  })
  initializePresentationControls(viewer, viewer.querySelector('[data-ppt-fullscreen]'))
  show(0)
}

document.addEventListener('DOMContentLoaded', () => {
  const viewer = document.querySelector('.ppt-viewer')
  if (viewer) initializePptViewer(viewer)
})
