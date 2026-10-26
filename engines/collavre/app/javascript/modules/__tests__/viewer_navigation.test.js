import { jest } from '@jest/globals'
import { bindViewerNavigation, updateViewerNavigation } from '../viewer_navigation'

function setup() {
  document.body.innerHTML = '<div tabindex="0"><button data-ppt-previous></button><button data-ppt-next></button><span data-ppt-counter></span><input><textarea></textarea><select></select><span contenteditable="true"></span></div>'
  const viewer = document.body.firstElementChild
  const actions = { previous: jest.fn(), next: jest.fn() }
  bindViewerNavigation(viewer, actions)
  return { viewer, actions }
}

test('shared navigation binds buttons and arrow keys and updates boundaries', () => {
  const { viewer, actions } = setup()
  updateViewerNavigation(viewer, 0, 2)
  expect(viewer.querySelector('[data-ppt-counter]').textContent).toBe('1 / 2')
  expect(viewer.querySelector('[data-ppt-previous]').disabled).toBe(true)
  viewer.querySelector('[data-ppt-next]').click()
  updateViewerNavigation(viewer, 1, 2)
  expect(viewer.querySelector('[data-ppt-next]').disabled).toBe(true)
  viewer.querySelector('[data-ppt-previous]').click()
  for (const key of ['ArrowLeft', 'ArrowRight']) {
    const event = new window.KeyboardEvent('keydown', { key, bubbles: true, cancelable: true })
    viewer.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  }
  expect(actions.previous).toHaveBeenCalledTimes(2)
  expect(actions.next).toHaveBeenCalledTimes(2)
})

test('ignores editing, unrelated keys and disconnected viewers', () => {
  const { viewer, actions } = setup()
  for (const target of viewer.querySelectorAll('input, textarea, select, [contenteditable]')) {
    const event = new window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })
    target.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(false)
  }
  viewer.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
  viewer.remove()
  document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
  expect(actions.next).not.toHaveBeenCalled()
  expect(actions.previous).not.toHaveBeenCalled()
})
