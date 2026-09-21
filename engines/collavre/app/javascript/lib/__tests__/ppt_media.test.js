import { applyPptFormatting } from '../ppt_formatting'
import { applyPptCrop, renderPptShape } from '../ppt_media'

function fixture(className, data, content = '<p>Linked label</p>') {
  document.body.innerHTML = `<div class="ppt-slide" data-ppt-format="{}"><div class="ppt-slide-element ${className}">${content}</div></div>`
  const element = document.querySelector('.ppt-slide-element')
  element.dataset.pptFormat = JSON.stringify(data)
  applyPptFormatting()
  return element
}

test('renders preset geometry with fill and contour without replacing labels or transforms', async () => {
  const element = fixture('ppt-slide-text', {shape:'triangle',fill:'#abcdef',stroke:'#123456',strokeWidth:0.2,rotation:45,flipH:true})
  const svg = element.querySelector('svg'), label = element.querySelector('p')
  expect(svg.querySelector('polygon').getAttribute('points')).toBe('50,0 100,100 0,100')
  expect(svg.querySelector('polygon').getAttribute('fill')).toBe('#abcdef')
  expect(svg.querySelector('polygon').getAttribute('stroke')).toBe('#123456')
  expect(svg.querySelector('polygon').style.strokeWidth).toBe('0.2cqw')
  expect(element.style.backgroundColor).toBe('transparent')
  expect(element.style.boxShadow).toBe('none')
  expect(element.style.transform).toBe('rotate(45deg) scaleX(-1)')
  let mutations = 0
  const observer = new MutationObserver(records => { mutations += records.length })
  observer.observe(element, {childList:true,subtree:true})
  for (let i = 0; i < 5; i++) { applyPptFormatting(); await Promise.resolve() }
  observer.disconnect()
  expect(mutations).toBe(0)
  expect(element.querySelector('svg')).toBe(svg)
  expect(element.querySelector('p')).toBe(label)
  element.dataset.pptFormat = JSON.stringify({shape:'diamond',fill:'#000000'})
  applyPptFormatting()
  expect(element.querySelectorAll('svg')).toHaveLength(1)
  expect(element.querySelector('polygon').getAttribute('points')).toBe('50,0 100,50 50,100 0,50')
})

test('uses a closed geometry vocabulary and rejects CSS payloads', () => {
  for (const shape of ['rtTriangle','chevron','pentagon','hexagon','parallelogram','trapezoid','rightArrow','leftArrow','upArrow','downArrow','leftRightArrow']) {
    const element = fixture('ppt-slide-title', {shape,fill:'url(https://invalid)',stroke:'#000000',strokeWidth:-1})
    expect(element.querySelector('polygon').getAttribute('fill')).toBe('none')
    expect(element.querySelector('polygon').hasAttribute('stroke')).toBe(false)
  }
  for (const shape of ['__proto__','constructor','toString','url(evil)',null]) {
    expect(fixture('ppt-slide-text', {shape}).querySelector('svg')).toBeNull()
  }
  const outside = document.createElement('div')
  renderPptShape(outside, {shape:'triangle'})
  expect(outside.children).toHaveLength(0)
})

test('crops the source image within its transformed frame with asymmetric offsets', () => {
  const element = fixture('ppt-slide-image', {crop:[0.25,0.1,0.25,0.2],x:10,y:20,w:40,h:30,rotation:90,flipV:true}, '<img alt="photo">')
  const image = element.querySelector('img')
  expect(image.style.width).toBe('200%')
  expect(parseFloat(image.style.height)).toBeCloseTo(100 / 0.7)
  expect(image.style.left).toBe('-50%')
  expect(parseFloat(image.style.top)).toBeCloseTo(-10 / 0.7)
  expect(element.style.overflow).toBe('hidden')
  expect(element.style.transform).toBe('rotate(90deg) scaleY(-1)')
  expect(element.style.width).toBe('40%')
  applyPptCrop(element, [-0.5,0,0,0])
  expect(parseFloat(image.style.width)).toBeCloseTo(100 / 1.5)
  expect(parseFloat(image.style.left)).toBeCloseTo(50 / 1.5)
  applyPptCrop(element, [0,0,0,0])
  expect(image.style.width).toBe('100%')
  expect(image.style.left).toBe('0%')
})

test('rejects malformed crop rectangles and absent images', () => {
  for (const crop of [null,{},[],[0,0,0],[0,0,0,'0'],[NaN,0,0,0],[Infinity,0,0,0],[-2,0,0,0],[0.5,0,0.5,0],[0,1,0,0],[0.9999,0,0,0]]) {
    const element = fixture('ppt-slide-image', {crop}, '<img>')
    expect(element.querySelector('img').hasAttribute('style')).toBe(false)
  }
  const element = fixture('ppt-slide-image', {crop:[0,0,0,0]}, '')
  expect(element.hasAttribute('style')).toBe(false)
})
