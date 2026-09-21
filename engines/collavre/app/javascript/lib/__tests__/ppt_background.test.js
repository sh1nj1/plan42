import { applyPptFormatting } from '../ppt_formatting'
import { applyPptBackground, backgroundImage } from '../ppt_background'

const gradient = {type:'linear', angle:90, stops:[[100,'#ffffff'],[0,'#20406080']]}

test('preserves sorted stops, alpha and DrawingML direction without mutating data', () => {
  expect(backgroundImage(gradient)).toBe('linear-gradient(180deg, #20406080 0%, #ffffff 100%)')
  expect(gradient.stops[0][0]).toBe(100)
  expect(backgroundImage({...gradient,angle:270})).toContain('0deg')
})

test('renders gradients, hatch patterns and cropped background pictures on repeated formatting', async () => {
  document.body.innerHTML='<div class="ppt-slide"><div class="ppt-slide-background ppt-slide-image"><img src="/public-assets/blobs/test/image.png" alt=""></div><div class="ppt-slide-layout"><p>Content</p></div></div>'
  const slide=document.querySelector('.ppt-slide')
  const picture=slide.firstElementChild
  const image=picture.firstElementChild
  slide.dataset.pptFormat=JSON.stringify({background:gradient})
  picture.dataset.pptFormat=JSON.stringify({crop:[0.1,0,0.2,0]})
  applyPptFormatting(slide)
  expect(slide.style.backgroundImage).toContain('linear-gradient')
  expect(image.style.width).toBe('142.85714285714286%')
  const mutations=[]
  const observer=new MutationObserver(records=>mutations.push(...records))
  observer.observe(slide,{childList:true,subtree:true})
  applyPptFormatting(slide)
  document.dispatchEvent(new window.Event('turbo:load'))
  await Promise.resolve()
  expect(mutations).toHaveLength(0)
  expect(slide.firstElementChild.firstElementChild).toBe(image)
  observer.disconnect()
  slide.dataset.pptFormat=JSON.stringify({background:{type:'pattern',preset:'diagCross',foreground:'#12345680',background:'#ffffff'}})
  applyPptFormatting(slide)
  expect(slide.style.backgroundImage).toContain('repeating-linear-gradient')
  expect(slide.textContent).toBe('Content')
})

test('uses only closed hatch vocabulary and independently validates all browser inputs', () => {
  for(const preset of ['horz','vert','cross','dnDiag','upDiag','diagCross','ltHorz','ltVert','ltDnDiag','ltUpDiag','dkHorz','dkVert','dkDnDiag','dkUpDiag','wdDnDiag','wdUpDiag']) {
    expect(backgroundImage({type:'pattern',preset,foreground:'#000000',background:'#ffffff'})).toContain('repeating-linear-gradient')
  }
  const invalid=[{}, {type:'evil'}, {...gradient,angle:'90'}, {...gradient,angle:Infinity}, {...gradient,stops:null}, {...gradient,stops:[]}, {...gradient,stops:Array(101).fill([0,'#ffffff'])}, ...[null,[0],[0,'red'],[-1,'#ffffff'],[101,'#ffffff'],['0','#ffffff'],[0,'#ffffff\n']].map(stop=>({...gradient,stops:[stop,[100,'#ffffff']]})), {type:'pattern',preset:'__proto__',foreground:'#000000',background:'#ffffff'}, {type:'pattern',preset:'horz',foreground:'url(https://evil)',background:'#ffffff'}]
  for(const data of invalid) expect(backgroundImage(data)).toBeUndefined()
  const slide=document.createElement('div')
  slide.className='ppt-slide'
  for(const data of [null,0,...invalid]) applyPptBackground(slide,data)
  expect(slide.style.backgroundImage).toBe('')
  applyPptBackground(document.createElement('p'),gradient)
})

test('clips non-solid shape fills while preserving labels outlines crops and DOM identity', async () => {
  document.body.innerHTML = '<div class="ppt-slide" data-ppt-format="{}"><div class="ppt-slide-text ppt-slide-element"><p>Label</p></div><div class="ppt-slide-title"><div class="ppt-shape-fill ppt-slide-image" data-ppt-format=\'{"crop":[0.1,0,0.2,0]}\'><img src="/public-assets/blobs/test/image.png" alt=""></div><p>Picture</p></div></div>'
  const shape = document.querySelector('.ppt-slide-text')
  const picture = document.querySelector('.ppt-slide-title')
  shape.dataset.pptFormat = JSON.stringify({shape:'triangle', fill:'#20406080', background:gradient, stroke:'#123456', strokeWidth:0.1})
  picture.dataset.pptFormat = JSON.stringify({shape:'ellipse'})
  applyPptFormatting()
  const layer = shape.querySelector('.ppt-shape-fill')
  expect(layer.style.backgroundImage).toContain('linear-gradient')
  expect(layer.style.clipPath).toBe('polygon(50% 0%, 100% 100%, 0% 100%)')
  expect(shape.querySelector('polygon').getAttribute('fill')).toBe('none')
  expect(shape.querySelector('polygon').getAttribute('stroke')).toBe('#123456')
  expect(picture.firstElementChild.style.borderRadius).toBe('50%')
  expect(picture.querySelector('img').style.width).toBe('142.85714285714286%')
  const mutations=[]
  const observer=new MutationObserver(records=>mutations.push(...records))
  observer.observe(document.body,{childList:true,subtree:true})
  applyPptFormatting()
  await Promise.resolve()
  expect(mutations).toHaveLength(0)
  expect(shape.querySelector('.ppt-shape-fill')).toBe(layer)
  observer.disconnect()
  shape.dataset.pptFormat=JSON.stringify({shape:'triangle', background:{type:'pattern',preset:'cross',foreground:'#123456',background:'#ffffff'}})
  applyPptFormatting()
  expect(layer.style.backgroundImage).toContain('repeating-linear-gradient')
  expect(shape.textContent).toBe('Label')
})

test('rejects malformed shape fills and does not create arbitrary image URLs', () => {
  document.body.innerHTML='<div class="ppt-slide" data-ppt-format="{}"><div class="ppt-slide-text"><p>Label</p></div></div>'
  const shape=document.querySelector('.ppt-slide-text')
  for(const background of [null, 'url(https://evil)', {}, {type:'image',url:'javascript:evil'}, {...gradient,stops:[[0,'red'],[100,'#ffffff']]}]) {
    shape.dataset.pptFormat=JSON.stringify({background})
    applyPptFormatting()
    expect(shape.querySelector('.ppt-shape-fill')).toBeNull()
  }
})
