import { renderPptConnector } from '../ppt_connector'
import { applyPptFormatting } from '../ppt_formatting'

const source = () => ({kind:'straightConnector1', width:6000000, height:3000000, slideWidth:12000000, weight:25400, stroke:'#ff0000', hidden:false, head:{type:'oval'}, tail:{type:'triangle', width:'sm', length:'lg'}})
const element = () => Object.assign(document.createElement('div'), {className:'ppt-slide-element ppt-slide-connector'})

test('renders connected endpoints and directional markers once per data version', () => {
  const node = element(), data = source()
  renderPptConnector(node, data)
  const path = node.querySelector('svg > path')
  expect(path.getAttribute('d')).toBe('M0 0L6000000 3000000')
  expect(path.getAttribute('stroke')).toBe('#ff0000')
  expect(path.getAttribute('stroke-width')).toBe('25400')
  expect(node.querySelectorAll('marker')).toHaveLength(2)
  expect(node.querySelectorAll('marker')[1].getAttribute('markerWidth')).toBe('5')
  expect(node.querySelectorAll('marker')[1].getAttribute('markerHeight')).toBe('2')
  expect(path.getAttribute('marker-end')).toBe(`url(#${node.querySelectorAll('marker')[1].id})`)
  renderPptConnector(node, data)
  expect(node.querySelector('svg > path')).toBe(path)
  renderPptConnector(node, {...data, hidden:true})
  expect(node.querySelectorAll('svg')).toHaveLength(1)
  expect(node.querySelector('path')).toBeNull()
})

test('renders bends curves adjustments and every supported arrow shape', () => {
  for (const kind of ['line','straightConnector1','bentConnector2','bentConnector3','bentConnector4','bentConnector5','curvedConnector2','curvedConnector3','curvedConnector4','curvedConnector5']) {
    const node = element()
    renderPptConnector(node, {...source(), kind, adjustments:{adj1:0.25, adj2:0.75, adj3:0.6}})
    expect(node.querySelector('svg > path').getAttribute('d')).toMatch(/^M0 0/)
    expect(node.querySelector('svg > path').getAttribute('d')).not.toContain('NaN')
    if (kind === 'bentConnector3') expect(node.querySelector('svg > path').getAttribute('d')).toBe('M0 0H1500000V3000000H6000000')
  }
  for (const type of ['stealth','arrow','diamond','oval','triangle','none','constructor']) {
    const node = element()
    renderPptConnector(node, {...source(), head:null, tail:{type, width:'bad', length:'med'}})
    expect(node.querySelectorAll('marker')).toHaveLength(['none','constructor'].includes(type) ? 0 : 1)
    if (type === 'arrow') expect(node.querySelector('marker path').getAttribute('fill')).toBe('none')
  }
})

test('retains zero extents and formats orientation without drawing a rectangular border', () => {
  document.body.innerHTML='<div class="ppt-slide" data-ppt-width="12000000" data-ppt-height="6000000" data-ppt-format="{}"></div>'
  const root = document.body.firstElementChild, node = element()
  root.append(node)
  node.dataset.pptFormat = JSON.stringify({x:10,y:20,w:50,h:0,rotation:90,flipV:true,connector:{...source(),height:0}})
  applyPptFormatting(root)
  expect(node.style.height).toBe('0%')
  expect(node.style.transform).toBe('rotate(90deg) scaleY(-1)')
  expect(node.style.boxShadow).toBe('')
  expect(node.querySelector('svg').style.height).toBe(`${12700/12000000*100}cqw`)
  renderPptConnector(node, {...source(),width:0})
  expect(node.querySelector('svg').style.width).toBe(`${12700/12000000*100}cqw`)
})

test('rejects invalid connector metadata and ignores untrusted arrow and adjustment tokens', () => {
  for (const data of [null,{}, {...source(),stroke:'url(https://invalid)'}, {...source(),width:-1}, {...source(),height:Infinity}, {...source(),weight:1e20}, {...source(),slideWidth:0}, {...source(),hidden:'false'}, {...source(),kind:'constructor'}]) {
    const node=element()
    renderPptConnector(node,data)
    expect(node.childElementCount).toBe(0)
  }
  const other = document.createElement('div')
  renderPptConnector(other,source())
  expect(other.childElementCount).toBe(0)
  const node=element()
  renderPptConnector(node,{...source(),kind:'bentConnector3',head:{type:'url(#bad)'},tail:{type:'<script/>'},adjustments:{adj1:'0;bad'}})
  expect(node.querySelectorAll('marker')).toHaveLength(0)
  expect(node.querySelector('path').getAttribute('d')).toBe('M0 0H3000000V3000000H6000000')
})

test('preserves alpha for connector strokes and arrowheads with strict hex validation', () => {
  const node = element()
  renderPptConnector(node, {...source(),stroke:'#ff000080'})
  expect(node.querySelector('svg > path').getAttribute('stroke')).toBe('#ff000080')
  expect(node.querySelector('marker path').getAttribute('fill')).toBe('#ff000080')
  for (const stroke of ['#1234567','#123456789','#123456zz','#12345680; color:red']) {
    const invalid = element()
    renderPptConnector(invalid, {...source(),stroke})
    expect(invalid.querySelector('svg')).toBeNull()
  }
})
