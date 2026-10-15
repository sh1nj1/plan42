import { jest } from '@jest/globals'
import { initializePdfDocument } from '../pdf_document'

const settle = () => new Promise(resolve => setTimeout(resolve, 0))
function setup() {
  document.body.innerHTML = `<div id="viewer"><div data-pdf-src="/report.pdf" data-pdf-worker="/worker.js"></div><span class="media-loading"></span><button data-ppt-previous></button><button data-ppt-next></button><span data-ppt-counter></span><button data-pdf-zoom></button><span data-document-error hidden></span></div>`
  Object.defineProperty(document.querySelector('[data-pdf-src]'), 'clientWidth', { value: 600 })
  window.HTMLCanvasElement.prototype.getContext = jest.fn().mockReturnValue({})
  return document.querySelector('#viewer')
}

test('renders one PDF page at a time with navigation, bounded zoom, loading and errors', async () => {
  const viewer = setup()
  const render = jest.fn().mockReturnValue({ promise: Promise.resolve() })
  const getViewport = jest.fn(({scale}) => ({width: 400 * scale, height: 600 * scale}))
  const getPage = jest.fn().mockResolvedValue({getViewport, render})
  const worker = {}
  await initializePdfDocument(viewer, async () => ({getDocument: options => { expect(options.url).toBe('/report.pdf'); return ({promise: Promise.resolve({numPages: 2, getPage})}) }, GlobalWorkerOptions: worker}))
  expect(worker.workerSrc).toBe('/worker.js')
  expect(viewer.querySelector('canvas').width).toBe(600)
  expect(viewer.querySelector('.media-loading').hidden).toBe(true)
  expect(viewer.querySelector('[data-ppt-previous]').disabled).toBe(true)
  viewer.querySelector('[data-ppt-next]').click()
  await settle()
  expect(viewer.querySelector('[data-ppt-counter]').textContent).toBe('2 / 2')
  expect(viewer.querySelector('[data-ppt-next]').disabled).toBe(true)
  viewer.querySelector('[data-ppt-previous]').click()
  await settle()
  viewer.querySelector('[data-pdf-zoom]').click()
  await settle()
  expect(viewer.querySelector('canvas').width).toBe(900)
  viewer.querySelector('[data-pdf-zoom]').click()
  await settle()
  expect(viewer.querySelector('canvas').width).toBe(600)
  getPage.mockRejectedValueOnce(new Error('Invalid page'))
  viewer.querySelector('[data-ppt-next]').click()
  await settle()
  expect(viewer.querySelector('[data-document-error]').hidden).toBe(false)
  expect(viewer.querySelector('.media-loading').hidden).toBe(true)
})

test('failed PDF and worker loads show a translated error and remove the loader', async () => {
  const viewer = setup()
  await initializePdfDocument(viewer, async () => { throw new Error('Failed') })
  expect(viewer.querySelector('[data-document-error]').hidden).toBe(false)
  expect(viewer.querySelector('.media-loading').hidden).toBe(true)
  await initializePdfDocument(document.createElement('div'))
})
