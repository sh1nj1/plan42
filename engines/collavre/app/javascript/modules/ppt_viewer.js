export function initializePptViewer(viewer) {
  const slides = Array.from(viewer.querySelectorAll('.ppt-viewer-slide'))
  const previous = viewer.querySelector('[data-ppt-previous]')
  const next = viewer.querySelector('[data-ppt-next]')
  const fullscreen = viewer.querySelector('[data-ppt-fullscreen]')
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
    if (event.key === 'Escape' && document.fullscreenElement) {
      toggleFullscreen()
      return
    }
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return
    event.preventDefault()
    show(index + (event.key === 'ArrowRight' ? 1 : -1))
  })
  fullscreen.hidden = typeof viewer.requestFullscreen !== 'function'
  async function toggleFullscreen() {
    const error = viewer.querySelector('[data-ppt-error]')
    error.hidden = true
    try {
      if (document.fullscreenElement) await document.exitFullscreen()
      else await viewer.requestFullscreen()
      viewer.focus()
    } catch {
      error.hidden = false
    }
  }
  fullscreen.addEventListener('click', toggleFullscreen)
  show(0)
}

document.addEventListener('DOMContentLoaded', () => {
  const viewer = document.querySelector('.ppt-viewer')
  if (viewer) initializePptViewer(viewer)
})
