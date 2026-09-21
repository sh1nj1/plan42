const rendered = new WeakMap()
let markerId = 0
const finite = (value, min, max) => typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max
const svgNode = (name, attributes) => {
  const node = document.createElementNS('http://www.w3.org/2000/svg', name)
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value))
  return node
}

// Imported XML never becomes SVG markup, attribute names, URLs or path commands.
export function renderPptConnector(element, data) {
  if (!element.classList.contains('ppt-slide-connector') || !validConnector(data)) return
  const signature = JSON.stringify(data)
  if (rendered.get(element) === signature) return
  const width = Math.max(data.width, 12700), height = Math.max(data.height, 12700)
  const svg = svgNode('svg', {viewBox:`0 0 ${width} ${height}`, preserveAspectRatio:'none', 'aria-hidden':'true'})
  Object.assign(svg.style, {width:'100%', height:'100%', overflow:'visible', display:'block'})
  if (data.width === 0) svg.style.width = `${12700 / data.slideWidth * 100}cqw`
  if (data.height === 0) svg.style.height = `${12700 / data.slideWidth * 100}cqw`
  if (!data.hidden) {
    const path = svgNode('path', {d:connectorPath(data), fill:'none', stroke:data.stroke, 'stroke-width':data.weight})
    addMarker(svg, path, data.head, {end:'start', color:data.stroke})
    addMarker(svg, path, data.tail, {end:'end', color:data.stroke})
    svg.append(path)
  }
  element.querySelector(':scope > svg')?.remove()
  element.append(svg)
  rendered.set(element, signature)
}

function validConnector(data) {
  return data && /^#[\da-f]{6}$/i.test(data.stroke) && finite(data.width,0,1e9) && finite(data.height,0,1e9) &&
    finite(data.weight,0,1e7) && finite(data.slideWidth,1,1e9) && typeof data.hidden === 'boolean' &&
    /^(line|straightConnector1|bentConnector[2-5]|curvedConnector[2-5])$/.test(data.kind)
}

function connectorPath(data) {
  const w = data.width, h = data.height
  const adjustment = key => finite(data.adjustments?.[key], -10, 10) ? data.adjustments[key] : 0.5
  const x = w * adjustment('adj1'), y = h * adjustment('adj2'), z = w * adjustment('adj3')
  const paths = {
    line:`M0 0L${w} ${h}`, straightConnector1:`M0 0L${w} ${h}`,
    bentConnector2:`M0 0H${w}V${h}`, bentConnector3:`M0 0H${x}V${h}H${w}`,
    bentConnector4:`M0 0H${x}V${y}H${w}V${h}`, bentConnector5:`M0 0H${x}V${y}H${z}V${h}H${w}`,
    curvedConnector2:`M0 0Q${w} 0 ${w} ${h}`,
    curvedConnector3:`M0 0C${x} 0 ${x} ${h} ${w} ${h}`,
    curvedConnector4:`M0 0C${x} 0 ${x} ${y} ${x} ${y}S${w} ${y} ${w} ${h}`,
    curvedConnector5:`M0 0C${x} 0 ${x} ${y} ${x} ${y}S${z} ${y} ${z} ${y}S${z} ${h} ${w} ${h}`
  }
  return paths[data.kind]
}

function addMarker(svg, path, arrow, options) {
  const shapes = {triangle:'M0 0L6 3L0 6Z', stealth:'M0 0L6 3L0 6L2 3Z', arrow:'M0 0L6 3L0 6', diamond:'M0 3L3 0L6 3L3 6Z', oval:'M0 3a3 3 0 1 0 6 0a3 3 0 1 0 -6 0'}
  if (!arrow || !Object.hasOwn(shapes, arrow.type)) return
  const sizes = {sm:2, med:3, lg:5}
  const size = value => Object.hasOwn(sizes, value) ? sizes[value] : 3
  const id = `ppt-connector-${++markerId}`
  const marker = svgNode('marker', {id, viewBox:'0 0 6 6', refX:6, refY:3, markerWidth:size(arrow.length), markerHeight:size(arrow.width), orient:'auto-start-reverse', markerUnits:'strokeWidth', overflow:'visible'})
  marker.append(svgNode('path', {d:shapes[arrow.type], fill:arrow.type === 'arrow' ? 'none' : options.color, stroke:options.color, 'stroke-width':0.5}))
  svg.append(marker)
  path.setAttribute(`marker-${options.end}`, `url(#${id})`)
}
