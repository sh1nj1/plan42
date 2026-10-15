import { jest } from '@jest/globals'
import { initializePptViewer } from '../ppt_viewer'

function setup(fullscreen = true) {
  document.body.innerHTML = `<div class="ppt-viewer" tabindex="0"><div class="ppt-viewer-slide">One <a href="https://example.com">Link</a></div><div class="ppt-viewer-slide">Two</div><button data-ppt-previous></button><button data-ppt-next></button><span data-ppt-counter></span><button data-ppt-fullscreen></button><button data-ppt-close></button><a href="/download">Download</a><span data-ppt-error hidden></span></div>`
  window.matchMedia = jest.fn().mockReturnValue({ matches: false })
  const viewer = document.querySelector('.ppt-viewer')
  if (fullscreen) viewer.requestFullscreen = jest.fn().mockResolvedValue(undefined)
  document.exitFullscreen = jest.fn().mockResolvedValue(undefined)
  Object.defineProperty(document, 'fullscreenElement', { configurable: true, value: null })
  initializePptViewer(viewer)
  return viewer
}

const tick = () => new Promise(resolve => setTimeout(resolve, 0))

test('buttons and arrow keys navigate within bounds', () => {
  const viewer = setup()
  const counter = viewer.querySelector('[data-ppt-counter]')
  const previous = viewer.querySelector('[data-ppt-previous]')
  const next = viewer.querySelector('[data-ppt-next]')
  expect(counter.textContent).toBe('1 / 2')
  expect(previous.disabled).toBe(true)
  next.click()
  expect(counter.textContent).toBe('2 / 2')
  expect(next.disabled).toBe(true)
  expect(viewer.querySelectorAll('.ppt-viewer-slide')[0].hidden).toBe(true)
  previous.click()
  for (const key of ['ArrowLeft', 'ArrowRight', 'ArrowRight', 'ArrowLeft']) {
    const event = new window.KeyboardEvent('keydown', { key, bubbles: true, cancelable: true })
    viewer.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  }
  expect(counter.textContent).toBe('1 / 2')
  const event = new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })
  viewer.dispatchEvent(event)
  expect(event.defaultPrevented).toBe(false)
})

test('fullscreen toggles, restores focus, and displays failures', async () => {
  const viewer = setup()
  const button = viewer.querySelector('[data-ppt-fullscreen]')
  button.click()
  await tick()
  expect(viewer.requestFullscreen).toHaveBeenCalledTimes(1)
  expect(document.activeElement).toBe(viewer)
  Object.defineProperty(document, 'fullscreenElement', { configurable: true, value: viewer })
  button.click()
  await tick()
  expect(document.exitFullscreen).toHaveBeenCalledTimes(1)
  viewer.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
  await tick()
  expect(document.exitFullscreen).toHaveBeenCalledTimes(2)
  document.exitFullscreen.mockRejectedValueOnce(new Error('Denied'))
  button.click()
  await tick()
  expect(viewer.querySelector('[data-ppt-error]').hidden).toBe(false)
})

test('hides unsupported fullscreen and initializes only viewer pages', () => {
  const viewer = setup(false)
  expect(viewer.querySelector('[data-ppt-fullscreen]').hidden).toBe(true)
  document.dispatchEvent(new window.Event('DOMContentLoaded'))
  expect(viewer.querySelector('[data-ppt-counter]').textContent).toBe('1 / 2')
  document.body.innerHTML = ''
  document.dispatchEvent(new window.Event('DOMContentLoaded'))
})

test('sizes the embedding frame from validated presentation dimensions', () => {
  const frame = document.createElement('iframe')
  Object.defineProperty(window, 'frameElement', { configurable: true, value: frame })
  const viewer = setup()
  const slide = document.createElement('div')
  slide.className = 'ppt-slide'
  viewer.prepend(slide)
  for (const [width, height] of [[9144000, 6858000], [12192000, 6858000], [6858000, 9144000]]) {
    slide.dataset.pptWidth = width
    slide.dataset.pptHeight = height
    initializePptViewer(viewer)
    expect(frame.style.aspectRatio).toBe(`${width} / ${height}`)
  }
  for (const [width, height] of [[0, 1], [1, -1], ['invalid', 1], [Infinity, 1], [1, 1e10]]) {
    frame.style.aspectRatio = ''
    slide.dataset.pptWidth = width
    slide.dataset.pptHeight = height
    initializePptViewer(viewer)
    expect(frame.style.aspectRatio).toBe('')
  }
  Object.defineProperty(window, 'frameElement', { configurable: true, value: null })
})

test('desktop slide click enters fullscreen but links and controls do not', async () => {
  const viewer = setup()
  viewer.querySelector('a').addEventListener('click', event => event.preventDefault())
  viewer.querySelector('a').click()
  viewer.querySelector('[data-ppt-next]').click()
  expect(viewer.requestFullscreen).not.toHaveBeenCalled()
  viewer.querySelector('.ppt-viewer-slide').click()
  await tick()
  expect(viewer.requestFullscreen).toHaveBeenCalledTimes(1)
  Object.defineProperty(document, 'fullscreenElement', { configurable: true, value: viewer })
  viewer.click()
  expect(document.exitFullscreen).not.toHaveBeenCalled()
  viewer.querySelector('[data-ppt-close]').click()
  await tick()
  expect(document.exitFullscreen).toHaveBeenCalledTimes(1)
})

test('touch taps toggle controls without entering fullscreen; buttons remain independent', async () => {
  const viewer = setup()
  window.matchMedia.mockReturnValue({ matches: true })
  viewer.click()
  expect(viewer.classList.contains('ppt-controls-visible')).toBe(true)
  viewer.querySelector('[data-ppt-next]').click()
  expect(viewer.classList.contains('ppt-controls-visible')).toBe(true)
  viewer.click()
  expect(viewer.classList.contains('ppt-controls-visible')).toBe(false)
  expect(viewer.requestFullscreen).not.toHaveBeenCalled()
  viewer.querySelector('[data-ppt-fullscreen]').click()
  await tick()
  expect(viewer.requestFullscreen).toHaveBeenCalledTimes(1)
  viewer.classList.add('ppt-controls-visible')
  document.dispatchEvent(new window.Event('fullscreenchange'))
  expect(viewer.classList.contains('ppt-controls-visible')).toBe(false)
})

test('keyboard opens fullscreen and unsupported browsers ignore slide activation', async () => {
  const viewer = setup()
  for (const key of ['Enter', ' ']) {
    const event = new window.KeyboardEvent('keydown', { key, bubbles: true, cancelable: true })
    viewer.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  }
  await tick()
  expect(viewer.requestFullscreen).toHaveBeenCalledTimes(2)
  const unsupported = setup(false)
  unsupported.click()
  unsupported.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
  expect(document.exitFullscreen).not.toHaveBeenCalled()
})

test('slide links open outside the iframe without changing download targets', () => {
  const viewer = setup()
  const link = viewer.querySelector('.ppt-viewer-slide a')
  expect(link.target).toBe('_blank')
  expect(link.rel).toBe('noopener noreferrer')
  expect(viewer.querySelector('a[href="/download"]').target).toBe('')
})
