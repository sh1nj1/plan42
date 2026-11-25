import { readFileSync } from 'node:fs'
import { jest } from '@jest/globals'
import { initializePdfDocument } from '../pdf_document'

const settle = () => new Promise(resolve => setTimeout(resolve, 0))
function setup() {
  document.body.innerHTML = `<div id="viewer"><div data-pdf-src="/report.pdf" data-pdf-worker="/worker.js"></div><span class="media-loading"></span><button data-ppt-previous></button><button data-ppt-next></button><span data-ppt-counter></span><button data-pdf-zoom></button><span data-document-error hidden></span></div>`
  Object.defineProperty(document.querySelector('[data-pdf-src]'), 'clientWidth', { value: 600, configurable: true })
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

test('coalesces resizes during rendering and uses the latest container width', async () => {
  const viewer = setup()
  const content = viewer.querySelector('[data-pdf-src]')
  let finishRender
  const render = jest.fn().mockImplementationOnce(() => ({ promise: new Promise(resolve => { finishRender = resolve }) }))
    .mockReturnValue({ promise: Promise.resolve() })
  const getViewport = ({ scale }) => ({ width: 400 * scale, height: 600 * scale })
  const getPage = jest.fn().mockResolvedValue({ getViewport, render })
  const initialized = initializePdfDocument(viewer, async () => ({
    getDocument: () => ({ promise: Promise.resolve({ numPages: 1, getPage }) }), GlobalWorkerOptions: {}
  }))
  await settle()
  Object.defineProperty(content, 'clientWidth', { value: 800, configurable: true })
  window.dispatchEvent(new window.Event('resize'))
  Object.defineProperty(content, 'clientWidth', { value: 1000, configurable: true })
  window.dispatchEvent(new window.Event('resize'))
  expect(render).toHaveBeenCalledTimes(1)
  expect(viewer.querySelector('.media-loading').hidden).toBe(false)
  finishRender()
  await initialized
  await settle()
  expect(render).toHaveBeenCalledTimes(2)
  expect(content.querySelector('canvas').width).toBe(1000)
  expect(viewer.querySelector('.media-loading').hidden).toBe(true)
  Object.defineProperty(content, 'clientWidth', { value: 700, configurable: true })
  window.dispatchEvent(new window.Event('resize'))
  await settle()
  expect(content.querySelector('canvas').width).toBe(700)
})


test('PDF entry point loads PDF.js and renders the document with the configured worker', async () => {
  const viewer = setup()
  viewer.classList.add('document-viewer')
  const render = jest.fn().mockReturnValue({ promise: Promise.resolve() })
  const getPage = jest.fn().mockResolvedValue({
    getViewport: ({ scale }) => ({ width: 400 * scale, height: 600 * scale }), render
  })
  const getDocument = jest.fn().mockReturnValue({ promise: Promise.resolve({ numPages: 1, getPage }) })
  const worker = {}
  jest.unstable_mockModule('pdfjs-dist', () => ({ getDocument, GlobalWorkerOptions: worker }))
  try {
    await import('../../collavre_pdf_viewer.js')
    await settle()
    expect(getDocument).toHaveBeenCalledWith({ url: '/report.pdf' })
    expect(worker.workerSrc).toBe('/worker.js')
    expect(viewer.querySelector('canvas').width).toBe(600)
    expect(viewer.querySelector('[data-ppt-counter]').textContent).toBe('1 / 1')
    expect(viewer.querySelector('.media-loading').hidden).toBe(true)
  } finally {
    jest.unstable_unmockModule('pdfjs-dist')
  }
})


test.each(['getPage', 'render'])('allows returning to a usable page after %s fails', async failure => {
  const viewer = setup()
  const page = {
    getViewport: ({ scale }) => ({ width: 400 * scale, height: 600 * scale }),
    render: jest.fn().mockReturnValue({ promise: Promise.resolve() })
  }
  const getPage = jest.fn().mockResolvedValue(page)
  await initializePdfDocument(viewer, async () => ({
    getDocument: () => ({ promise: Promise.resolve({ numPages: 2, getPage }) }), GlobalWorkerOptions: {}
  }))
  if (failure === 'getPage') getPage.mockRejectedValueOnce(new Error('Invalid page'))
  else page.render.mockImplementationOnce(() => ({ promise: Promise.reject(new Error('Render failed')) }))
  viewer.querySelector('[data-ppt-next]').click()
  await settle()
  expect(viewer.querySelector('[data-document-error]').hidden).toBe(false)
  expect(viewer.querySelector('[data-ppt-previous]').disabled).toBe(false)
  expect(viewer.querySelector('[data-ppt-next]').disabled).toBe(true)
  expect(viewer.querySelector('[data-ppt-counter]').textContent).toBe('2 / 2')
  viewer.querySelector('[data-ppt-previous]').click()
  await settle()
  expect(getPage).toHaveBeenLastCalledWith(1)
  expect(viewer.querySelector('[data-document-error]').hidden).toBe(true)
  expect(viewer.querySelector('[data-ppt-counter]').textContent).toBe('1 / 2')
  expect(viewer.querySelector('[data-ppt-previous]').disabled).toBe(true)
  expect(viewer.querySelector('[data-ppt-next]').disabled).toBe(false)
  expect(viewer.querySelector('.media-loading').hidden).toBe(true)
})


test.each([true, false])('queued render determines error state after an earlier failure (success: %s)', async succeeds => {
  const viewer = setup()
  let rejectRender
  const render = jest.fn()
    .mockImplementationOnce(() => ({ promise: new Promise((resolve, reject) => { rejectRender = reject }) }))
    .mockImplementation(() => ({ promise: succeeds ? Promise.resolve() : Promise.reject(new Error('Queued failure')) }))
  const getPage = jest.fn().mockResolvedValue({
    getViewport: ({ scale }) => ({ width: 400 * scale, height: 600 * scale }), render
  })
  const initialized = initializePdfDocument(viewer, async () => ({
    getDocument: () => ({ promise: Promise.resolve({ numPages: 1, getPage }) }), GlobalWorkerOptions: {}
  }))
  await settle()
  window.dispatchEvent(new window.Event('resize'))
  rejectRender(new Error('Earlier failure'))
  await initialized
  await settle()
  expect(render).toHaveBeenCalledTimes(2)
  expect(viewer.querySelector('[data-document-error]').hidden).toBe(succeeds)
  expect(viewer.querySelector('.media-loading').hidden).toBe(true)
  expect(Boolean(viewer.querySelector('canvas'))).toBe(succeeds)
})


test('PDF failures overlay the document area and remain hidden after recovery', async () => {
  const style = document.createElement('style')
  style.textContent = readFileSync('engines/collavre/app/assets/stylesheets/collavre/slide_view.css', 'utf8')
  document.head.append(style)
  const viewer = setup()
  viewer.classList.add('document-viewer')
  const content = document.createElement('div')
  content.id = 'slide-content'
  viewer.prepend(content)
  content.append(viewer.querySelector('[data-pdf-src]'), viewer.querySelector('.media-loading'), viewer.querySelector('[data-document-error]'))
  const error = viewer.querySelector('[data-document-error]')
  try {
    expect(getComputedStyle(error).display).toBe('none')
    await initializePdfDocument(viewer, async () => { throw new Error('Load failed') })
    expect(getComputedStyle(content).position).toBe('relative')
    expect(getComputedStyle(error).position).toBe('absolute')
    expect(getComputedStyle(error).inset).toBe('0')
    expect(getComputedStyle(error).display).toBe('grid')
    expect(getComputedStyle(error).placeItems).toBe('center')
    const getPage = async () => ({
      getViewport: () => ({ width: 400, height: 600 }),
      render: () => ({ promise: Promise.resolve() })
    })
    await initializePdfDocument(viewer, async () => ({
      getDocument: () => ({ promise: Promise.resolve({ numPages: 1, getPage }) }), GlobalWorkerOptions: {}
    }))
    expect(getComputedStyle(error).display).toBe('none')
    expect(content.querySelector('canvas')).not.toBeNull()
  } finally {
    style.remove()
  }
})


test.each([1, 2, 1.5])('renders PDF at device pixel ratio %s without changing CSS size', async ratio => {
  const viewer = setup()
  const previousRatio = window.devicePixelRatio
  window.devicePixelRatio = ratio
  const render = jest.fn().mockReturnValue({ promise: Promise.resolve() })
  const getPage = async () => ({
    getViewport: ({ scale }) => ({ width: 400 * scale, height: 600 * scale }), render
  })
  try {
    await initializePdfDocument(viewer, async () => ({
      getDocument: () => ({ promise: Promise.resolve({ numPages: 1, getPage }) }), GlobalWorkerOptions: {}
    }))
    const canvas = viewer.querySelector('canvas')
    expect(canvas.width).toBe(600 * ratio)
    expect(canvas.height).toBe(900 * ratio)
    expect(canvas.style.width).toBe('600px')
    expect(canvas.style.height).toBe('900px')
    expect(render.mock.calls[0][0].transform).toEqual([ratio, 0, 0, ratio, 0, 0])
  } finally {
    window.devicePixelRatio = previousRatio
  }
})
