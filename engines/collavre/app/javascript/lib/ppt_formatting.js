import { renderPptConnector } from "./ppt_connector"
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
  if (data.connector) renderPptConnector(element, data.connector)
  const style = element.style
  applyTableDimensions(element, data)
  applyGeometry(element, slide, data)
  applyTextStyle(style, data)
  applyShapeStyle(style, data)
}

function applyTableDimensions(element, data) {
  if (!element.matches('table.ppt-slide-table')) return
  const proportions = values => Array.isArray(values) && values.length > 0 && values.every(value => finite(value, 0.000001, 100)) && Math.abs(values.reduce((sum, value) => sum + value, 0) - 100) < 0.01
  if (proportions(data.columns)) applyTableColumns(element, data.columns)
  if (proportions(data.rows) && data.rows.length === element.rows.length) {
    Array.from(element.rows).forEach((row, index) => { row.style.height = `${data.rows[index]}%` })
  }
}

function applyTableColumns(table, widths) {
  let group = table.querySelector(':scope > colgroup')
  if (!group || group.children.length !== widths.length || [...group.children].some(column => column.tagName !== 'COL')) {
    group?.remove()
    group = document.createElement('colgroup')
    for (let index = 0; index < widths.length; index++) group.append(document.createElement('col'))
    table.prepend(group)
  }
  // Keep the nodes stable: the slide observer also sees renderer-owned children.
  Array.from(group.children).forEach((column, index) => { column.style.width = `${widths[index]}%` })
}

function applyGeometry(element, slide, data) {
  const style = element.style
  if (element !== slide && element.classList.contains('ppt-slide-element')) {
    for (const [key, property] of Object.entries({ x: 'left', y: 'top', w: 'width', h: 'height' })) {
      if (finite(data[key], key === 'x' || key === 'y' ? -1000 : 0, 1000)) style[property] = `${data[key]}%`
    }
    applyOrientation(style, data)
    if (['x', 'y', 'w', 'h'].every(key => finite(data[key], -1000, 1000))) style.position = 'absolute'
  }
}

function applyOrientation(style, data) {
  const transforms = []
  if (finite(data.rotation, 0, 360)) transforms.push(`rotate(${data.rotation}deg)`)
  if (typeof data.flipH === 'boolean') transforms.push(`scaleX(${data.flipH ? -1 : 1})`)
  if (typeof data.flipV === 'boolean') transforms.push(`scaleY(${data.flipV ? -1 : 1})`)
  if (transforms.length) {
    style.transformOrigin = 'center center'
    style.transform = transforms.join(' ')
  }
}

function applyParagraphSpacing(style, data) {
  if (finite(data.marginLeft, 0, 100)) style.marginLeft = `${data.marginLeft}cqw`
  if (finite(data.textIndent, -100, 100)) style.textIndent = `${data.textIndent}cqw`
  for (const [key, property] of Object.entries({spaceBefore:'marginTop', spaceAfter:'marginBottom'})) {
    if (finite(data[key], 0, 100)) style[property] = `${data[key]}cqw`
    if (finite(data[`${key}Em`], 0, 100)) style[property] = `${data[`${key}Em`]}em`
  }
  if (finite(data.lineHeight, 0.5, 5)) style.lineHeight = String(data.lineHeight)
  if (finite(data.lineHeightPoints, 0.01, 100)) style.lineHeight = `${data.lineHeightPoints}cqw`
}

function applyTextStyle(style, data) {
  if (color(data.fill)) style.backgroundColor = data.fill
  if (color(data.color)) style.color = data.color
  if (finite(data.fontSize, 0.01, 100)) style.fontSize = `${data.fontSize}cqw`
  if (Object.hasOwn(fonts, data.font)) style.fontFamily = fonts[data.font]
  applyParagraphSpacing(style, data)
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
