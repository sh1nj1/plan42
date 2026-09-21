const shapes = {
  triangle: '50,0 100,100 0,100', rtTriangle: '0,0 100,100 0,100',
  diamond: '50,0 100,50 50,100 0,50', chevron: '0,0 50,0 100,50 50,100 0,100 50,50',
  pentagon: '50,0 100,38.2 80.9,100 19.1,100 0,38.2',
  hexagon: '25,0 75,0 100,50 75,100 25,100 0,50',
  parallelogram: '25,0 100,0 75,100 0,100', trapezoid: '25,0 75,0 100,100 0,100',
  rightArrow: '0,25 50,25 50,0 100,50 50,100 50,75 0,75',
  leftArrow: '100,25 50,25 50,0 0,50 50,100 50,75 100,75',
  upArrow: '25,100 25,50 0,50 50,0 100,50 75,50 75,100',
  downArrow: '25,0 25,50 0,50 50,100 100,50 75,50 75,0',
  leftRightArrow: '0,50 25,0 25,25 75,25 75,0 100,50 75,100 75,75 25,75 25,100'
}
const finite = (value, min, max) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max
const color = value => typeof value === 'string' && /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(value)
const rendered = new WeakMap()

// The polygon vocabulary is code-owned; presentation strings never become SVG.
export function renderPptShape(element, data) {
  if (!element.matches('.ppt-slide-text, .ppt-slide-title') || !Object.hasOwn(shapes, data.shape)) return
  element.style.backgroundColor = 'transparent'
  element.style.boxShadow = 'none'
  const signature = JSON.stringify([data.shape, data.fill, data.stroke, data.strokeWidth])
  if (rendered.get(element) === signature) return
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  svg.setAttribute('viewBox', '0 0 100 100')
  svg.setAttribute('preserveAspectRatio', 'none')
  svg.setAttribute('aria-hidden', 'true')
  const polygon = document.createElementNS(svg.namespaceURI, 'polygon')
  polygon.setAttribute('points', shapes[data.shape])
  polygon.setAttribute('fill', color(data.fill) ? data.fill : 'none')
  if (color(data.stroke) && finite(data.strokeWidth, 0, 10)) {
    polygon.setAttribute('stroke', data.stroke)
    polygon.setAttribute('vector-effect', 'non-scaling-stroke')
    polygon.style.strokeWidth = `${data.strokeWidth}cqw`
  }
  svg.append(polygon)
  element.querySelector(':scope > svg')?.remove()
  element.prepend(svg)
  element.classList.add('ppt-preset-rendered')
  rendered.set(element, signature)
}

export function applyPptCrop(element, crop) {
  if (!element.matches('.ppt-slide-image') || !Array.isArray(crop) || crop.length !== 4 || !crop.every(value => finite(value, -1, 1))) return
  const [left, top, right, bottom] = crop
  const width = 1 - left - right, height = 1 - top - bottom
  if (!finite(width, 0.001, 3) || !finite(height, 0.001, 3)) return
  const image = element.querySelector(':scope > img')
  if (!image) return
  element.style.overflow = 'hidden'
  Object.assign(image.style, {position:'absolute', width:`${100 / width}%`, height:`${100 / height}%`, left:`${-100 * left / width}%`, top:`${-100 * top / height}%`})
}
