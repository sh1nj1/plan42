const rendered = new WeakMap()
const validSeries = row => Array.isArray(row) && row.length === 3 && row[1] && row[2] && typeof row[1] === 'object' && typeof row[2] === 'object'
const svgNode = (name, attributes, text) => {
  const node = document.createElementNS('http://www.w3.org/2000/svg', name)
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value))
  if (text != null) node.textContent = String(text)
  return node
}

// The accessible source table stays in the DOM. The SVG is built only from
// finite numeric points and textContent labels, never imported markup.
export function renderPptChart(element, chart) {
  if (!element.classList.contains('ppt-slide-chart') || !chart || !Array.isArray(chart.series) || chart.series.length > 20) return
  const signature = JSON.stringify(chart)
  if (rendered.get(element) === signature) return
  const valid = chart.series.filter(validSeries)
  const indices = [...new Set(valid.flatMap(row => [...Object.keys(row[1]), ...Object.keys(row[2])]))].filter(key => /^\d{1,6}$/.test(key)).sort((a,b) => Number(a)-Number(b))
  if (!indices.length || indices.length > 1000) return
  const number = value => value != null && String(value).trim() !== '' && Number.isFinite(Number(value)) && Math.abs(Number(value)) <= 1e9 ? Number(value) : null
  const bounds = chartBounds(valid, chart, number)
  if (!bounds) return
  const { min, max } = bounds
  const svg = svgNode('svg', { viewBox: '0 0 600 400', role: 'img', 'aria-label': valid.map(row=>String(row[0])).join(', ') })
  const x = i => 55 + (i + 0.5) * 525 / indices.length
  const y = value => 350 - (value - min) * 320 / (max - min)
  for (let i=0;i<=4;i++) {
    const value = min + (max-min)*i/4
    svg.append(svgNode('line',{x1:55,x2:580,y1:y(value),y2:y(value),stroke:'#dddddd','stroke-width':1}))
    svg.append(svgNode('text',{x:43,y:y(value)+5,'text-anchor':'end',fill:'#696969','font-size':16},Number(value.toFixed(2))))
  }
  svg.append(svgNode('path',{d:'M55 30V350H580',fill:'none',stroke:'#888888','stroke-width':1}))
  indices.forEach((key,i)=>svg.append(svgNode('text',{x:x(i),y:379,'text-anchor':'middle',fill:'#696969','font-size':15},valid.find(row=>row[1][key]!=null)?.[1][key] ?? '')))
  valid.forEach((row,seriesIndex)=>{
    const color = ['#0062e5','#e76f51','#2a9d8f'][seriesIndex%3]
    let path = '', connected = false
    indices.forEach((key,i)=>{
      const value = number(row[2][key])
      if(value==null){ connected=false; return }
      path += `${connected?'L':'M'}${x(i)} ${y(value)} `
      connected=true
      svg.append(svgNode('circle',{cx:x(i),cy:y(value),r:5,fill:color}))
      svg.append(svgNode('text',{x:x(i),y:y(value)-14,'text-anchor':'middle',fill:'#696969','font-size':16},value))
    })
    svg.prepend(svgNode('path',{d:path,fill:'none',stroke:color,'stroke-width':4}))
  })
  element.querySelector(':scope > svg')?.remove()
  element.append(svg)
  element.classList.add('ppt-chart-rendered')
  rendered.set(element, signature)
}

function chartBounds(valid, chart, number) {
  const values = valid.flatMap(row => Object.values(row[2]).map(number)).filter(value => value != null)
  if (!values.length) return null
  const min = number(chart.min) ?? Math.min(0, ...values)
  const max = number(chart.max) ?? Math.max(1, ...values)
  if (max <= min) return null
  return { min, max }
}
