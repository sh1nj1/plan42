import { jest } from '@jest/globals'
import { initializePptViewer } from '../ppt_viewer'

function setup(fullscreen = true) {
  document.body.innerHTML = `<div class="ppt-viewer" tabindex="0"><div class="ppt-viewer-slide">One</div><div class="ppt-viewer-slide">Two</div><button data-ppt-previous></button><button data-ppt-next></button><span data-ppt-counter></span><button data-ppt-fullscreen></button><span data-ppt-error hidden></span></div>`
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
