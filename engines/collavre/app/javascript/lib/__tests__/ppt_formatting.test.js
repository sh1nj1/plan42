import { applyPptFormatting } from '../ppt_formatting'
import { renderPptChart } from '../ppt_chart'

function slide(data = {}) {
  document.body.innerHTML = '<div class="ppt-slide" data-ppt-width="12192000" data-ppt-height="6858000"><div class="ppt-slide-element"><p></p></div></div>'
  const root = document.querySelector('.ppt-slide')
  root.dataset.pptFormat = JSON.stringify({ fill: '#222222' })
  const element = root.firstElementChild
  element.dataset.pptFormat = JSON.stringify(data)
  return { root, element }
}

test('restores bounded coordinates, typography and shapes inside the slide', () => {
  const { root, element } = slide({ x:-10, y:12, w:110, h:35, fill:'#fedf00', color:'#ffffff', fontSize:2.5, font:'Malgun Gothic', lineHeight:1.2, spaceAfter:1, align:'ctr', shape:'ellipse', stroke:'#222222', strokeWidth:0.1, anchor:'ctr', insets:[1,2,3,4] })
  applyPptFormatting()
  expect(root.classList.contains('ppt-slide--precise')).toBe(true)
  expect(element.style.position).toBe('absolute')
  expect(element.style.left).toBe('-10%')
  expect(element.style.width).toBe('110%')
  expect(element.style.fontSize).toBe('2.5cqw')
  expect(element.style.color).toBe('rgb(255, 255, 255)')
  expect(element.style.fontFamily).toContain('Apple SD Gothic Neo')
  expect(element.style.marginBottom).toBe('1cqw')
  expect(element.style.borderRadius).toBe('50%')
  expect(element.style.padding).toBe('2cqw 3cqw 4cqw 1cqw')
  expect(element.style.justifyContent).toBe('center')
  element.dataset.pptFormat = JSON.stringify({shape:'roundRect'})
  applyPptFormatting(element)
  expect(element.style.borderRadius).toBe('0.7cqw')
})

test('ignores malformed data and CSS or out-of-bounds payloads', () => {
  const { root, element } = slide({ x:'0;position:fixed', y:1e9, w:-1, h:Infinity, fill:'url(https://invalid)', color:'expression(x)', fontSize:1e8, font:'__proto__', align:'toString', anchor:'constructor', insets:[1,-1,2,3], position:'fixed' })
  applyPptFormatting(root)
  expect(element.getAttribute('style')).toBeNull()
  for(const value of ['oops','null','[]','0']) {
    element.dataset.pptFormat=value
    applyPptFormatting(root)
    expect(element.getAttribute('style')).toBeNull()
  }
  root.removeAttribute('data-ppt-format')
  applyPptFormatting()
})

test('formats streamed descendants and turbo-loaded slides', async () => {
  const { root, element } = slide({fontSize:2})
  await new Promise(resolve=>setTimeout(resolve,0))
  expect(element.style.fontSize).toBe('2cqw')
  element.dataset.pptFormat = JSON.stringify({fontSize:3})
  document.dispatchEvent(new window.Event('turbo:load'))
  expect(element.style.fontSize).toBe('3cqw')
  root.dataset.pptWidth='invalid'
  applyPptFormatting(root)
})

function chartElement() {
  const element=document.createElement('div')
  element.className='ppt-slide-chart'
  element.innerHTML='<table><tbody><tr><td>Source data</td></tr></tbody></table>'
  return element
}

test('renders sparse line charts without shifting labels or joining across missing values', () => {
  const element=chartElement()
  const chart={min:0,max:20,series:[['PHQ',{'0':'1주','2':'3주','10':'<script>bad</script>'},{'0':'16','1':'','2':'15','10':'6'}]]}
  renderPptChart(element,chart)
  expect(element.querySelectorAll('circle')).toHaveLength(3)
  expect(element.querySelectorAll('script')).toHaveLength(0)
  expect(element.querySelector('svg').textContent).toContain('<script>bad</script>')
  expect(element.querySelector('path').getAttribute('d').match(/M/g)).toHaveLength(2)
  expect(element.querySelector('table').textContent).toBe('Source data')
  renderPptChart(element,chart)
  expect(element.querySelectorAll('svg')).toHaveLength(1)
  renderPptChart(element,{series:[['Changed',{'0':'A'},{'0':'1'}]]})
  expect(element.querySelectorAll('svg')).toHaveLength(1)
})

test('rejects invalid and oversized chart data without replacing the source table', () => {
  for(const data of [null,{}, {series:Array(21).fill([])}, {series:[null]}, {series:[['x',{},{}]]}, {series:[['x',{'0':'A'},{'0':'NaN'}]]}, {min:20,max:0,series:[['x',{'0':'A'},{'0':'2'}]]}, {series:[['x',{},Object.fromEntries(Array.from({length:1001},(_,i)=>[i,1]))]]}]) {
    const element=chartElement()
    renderPptChart(element,data)
    expect(element.querySelector('svg')).toBeNull()
  }
})

test('formats chart data embedded in a sanitized slide', () => {
  const { element }=slide({chart:{series:[['Data',{'0':'A'},{'0':'3'}]]}})
  element.classList.add('ppt-slide-chart')
  applyPptFormatting()
  expect(element.querySelectorAll('svg')).toHaveLength(1)
})

test('applies bounded orientation and inherited paragraph spacing', () => {
  const {root, element} = slide({rotation:90, flipH:true, flipV:false, spaceBefore:2, spaceAfterEm:0.5, lineHeightPoints:2.5})
  applyPptFormatting(root)
  expect(element.style.transform).toBe('rotate(90deg) scaleX(-1) scaleY(1)')
  expect(element.style.transformOrigin).toBe('center center')
  expect(element.style.marginTop).toBe('2cqw')
  expect(element.style.marginBottom).toBe('0.5em')
  expect(element.style.lineHeight).toBe('2.5cqw')
  element.dataset.pptFormat = JSON.stringify({rotation:270, flipH:false, flipV:true, spaceBeforeEm:1})
  applyPptFormatting(root)
  expect(element.style.transform).toBe('rotate(270deg) scaleX(1) scaleY(-1)')
  expect(element.style.marginTop).toBe('1em')
})

test('rejects orientation and spacing injection or invalid types', () => {
  const {root, element} = slide({rotation:'90deg);background:red', flipH:'true', flipV:1, spaceBefore:-1, spaceAfterEm:'2', lineHeightPoints:1000})
  applyPptFormatting(root)
  expect(element.getAttribute('style')).toBeNull()
})
