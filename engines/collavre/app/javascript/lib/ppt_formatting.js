import { renderPptChart } from "./ppt_chart"

// Do not interpret presentation data as CSS. Every accepted value has a bounded
// numeric type or a closed vocabulary; positions stay clipped by the canvas.
const finite = (value, min, max) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max
const color = value => typeof value === 'string' && /^#[\da-f]{6}$/i.test(value)
const fonts = {
  'Malgun Gothic': '"Malgun Gothic", "Apple SD Gothic Neo", Arial, sans-serif',
  Arial: 'Arial, sans-serif', Calibri: 'Calibri, Arial, sans-serif'
}

export function applyPptFormatting(root = document) {
  const slides = [...root.querySelectorAll('.ppt-slide')]
  if (root.matches?.('.ppt-slide')) slides.unshift(root)
  // A streamed child can arrive after its slide wrapper.
  const parent = root.closest?.('.ppt-slide')
  if (parent) slides.push(parent)
  for (const slide of new Set(slides)) {
    if (!slide.hasAttribute('data-ppt-format')) continue
    slide.classList.add('ppt-slide--precise')
    const width = Number(slide.dataset.pptWidth)
    const height = Number(slide.dataset.pptHeight)
    if (finite(width, 1, 1e9) && finite(height, 1, 1e9)) slide.style.aspectRatio = `${width} / ${height}`
    for (const element of [slide, ...slide.querySelectorAll('[data-ppt-format]')]) applyElementFormatting(element, slide)
  }
}

function applyElementFormatting(element, slide) {
  let data
  try { data = JSON.parse(element.dataset.pptFormat) } catch { return }
  if (!data || typeof data !== 'object' || Array.isArray(data)) return
  if (data.chart) renderPptChart(element, data.chart)
  const style = element.style
  applyGeometry(element, slide, data)
  applyTextStyle(style, data)
  applyShapeStyle(style, data)
}

function applyGeometry(element, slide, data) {
  const style = element.style
  if (element !== slide && element.classList.contains('ppt-slide-element')) {
    for (const [key, property] of Object.entries({ x: 'left', y: 'top', w: 'width', h: 'height' })) {
      if (finite(data[key], key === 'x' || key === 'y' ? -1000 : 0, 1000)) style[property] = `${data[key]}%`
    }
    if (['x', 'y', 'w', 'h'].every(key => finite(data[key], -1000, 1000))) style.position = 'absolute'
  }
}

function applyTextStyle(style, data) {
  if (color(data.fill)) style.backgroundColor = data.fill
  if (color(data.color)) style.color = data.color
  if (finite(data.fontSize, 0.01, 100)) style.fontSize = `${data.fontSize}cqw`
  if (Object.hasOwn(fonts, data.font)) style.fontFamily = fonts[data.font]
  if (finite(data.spaceAfter, 0, 100)) style.marginBottom = `${data.spaceAfter}cqw`
  if (finite(data.lineHeight, 0.5, 5)) style.lineHeight = String(data.lineHeight)
  if (Object.hasOwn({ l: 1, ctr: 1, r: 1, just: 1 }, data.align)) style.textAlign = { l: 'left', ctr: 'center', r: 'right', just: 'justify' }[data.align]
}

function applyShapeStyle(style, data) {
  if (data.shape === 'ellipse') style.borderRadius = '50%'
  if (data.shape === 'roundRect') style.borderRadius = '0.7cqw'
  if (color(data.stroke) && finite(data.strokeWidth, 0, 10)) style.boxShadow = `inset 0 0 0 ${data.strokeWidth}cqw ${data.stroke}`
  if (Object.hasOwn({ t: 1, ctr: 1, b: 1 }, data.anchor)) style.justifyContent = { t: 'flex-start', ctr: 'center', b: 'flex-end' }[data.anchor]
  if (Array.isArray(data.insets) && data.insets.length === 4 && data.insets.every(value => finite(value, 0, 100))) {
    const [left, top, right, bottom] = data.insets
    style.padding = `${top}cqw ${right}cqw ${bottom}cqw ${left}cqw`
  }
}

if (typeof document !== 'undefined') {
  applyPptFormatting()
  const observer = new MutationObserver(records => {
    for (const record of records) {
      for (const node of record.addedNodes) if (node.nodeType === 1) applyPptFormatting(node)
    }
  })
  observer.observe(document.documentElement, { childList: true, subtree: true })
  document.addEventListener('turbo:load', () => applyPptFormatting())
}
