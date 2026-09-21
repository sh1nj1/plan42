import { clipPptShapeFill } from './ppt_media'

// Only validated colors and numeric stops become CSS; PPT XML never supplies CSS.
const finite = (value, min, max) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max
const color = value => typeof value === 'string' && /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(value)
const patternAngles = { horz: [0], vert: [90], cross: [0,90], dnDiag: [135], upDiag: [45], diagCross: [45,135], ltHorz: [0], ltVert: [90], ltDnDiag: [135], ltUpDiag: [45], dkHorz: [0], dkVert: [90], dkDnDiag: [135], dkUpDiag: [45], wdDnDiag: [135], wdUpDiag: [45] }

export function applyPptBackground(element, data) {
  if (!element.matches('.ppt-slide') || !data || typeof data !== 'object') return
  const image = backgroundImage(data)
  if (image) element.style.backgroundImage = image
}

export function backgroundImage(data) {
  if (data.type === 'pattern') return patternImage(data)
  if (data.type !== 'linear' || !finite(data.angle, 0, 360)) return
  if (!Array.isArray(data.stops) || data.stops.length < 2 || data.stops.length > 100) return
  if (!data.stops.every(stop => Array.isArray(stop) && stop.length === 2 && finite(stop[0], 0, 100) && color(stop[1]))) return
  const stops = [...data.stops].sort((a,b) => a[0] - b[0]).map(([position, value]) => `${value} ${position}%`).join(', ')
  // DrawingML measures clockwise from right; CSS measures clockwise from up.
  return `linear-gradient(${(data.angle + 90) % 360}deg, ${stops})`
}

function patternImage(data) {
  if (!color(data.foreground) || !color(data.background)) return
  const angles = Object.hasOwn(patternAngles, data.preset) && patternAngles[data.preset]
  if (!angles) return
  const width = data.preset.startsWith('dk') ? 2 : 1
  const spacing = data.preset.startsWith('wd') ? 8 : 4
  const layers = angles.map(angle => `repeating-linear-gradient(${angle}deg, ${data.foreground} 0px, ${data.foreground} ${width}px, transparent ${width}px, transparent ${spacing}px)`)
  return [...layers, `linear-gradient(${data.background}, ${data.background})`].join(', ')
}

export function applyPptShapeFill(element, data) {
  if (!element.matches('.ppt-slide-text, .ppt-slide-title')) return
  let layer = element.querySelector(':scope > .ppt-shape-fill')
  const image = data.background && typeof data.background === 'object' && backgroundImage(data.background)
  if (!image && !layer) return
  if (!layer) {
    layer = document.createElement('div')
    layer.className = 'ppt-shape-fill'
    element.prepend(layer)
  }
  layer.setAttribute('aria-hidden', 'true')
  if (image) layer.style.backgroundImage = image
  clipPptShapeFill(element, layer, data.shape)
  element.style.backgroundColor = 'transparent'
}
