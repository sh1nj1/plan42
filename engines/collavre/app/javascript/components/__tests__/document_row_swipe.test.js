import { jest } from '@jest/globals'
import { attachDocumentRowSwipe } from '../document_row_swipe'

let root, row, body, detach
function touch(x, y, identifier = 1) { return { clientX: x, clientY: y, identifier } }
function send(type, points, time = 100, target = body, changed = points) {
  const event = new window.Event(type, { bubbles: true })
  Object.defineProperties(event, {
    touches: { value: points }, changedTouches: { value: changed }, timeStamp: { value: time }
  })
  target.dispatchEvent(event)
}
function swipe({ start = [250, 100], move = [150, 102], end = [140, 103], duration = 200, target = body } = {}) {
  send('touchstart', [touch(...start)], 100, target)
  send('touchmove', [touch(...move)], 150, target)
  send('touchend', [], 100 + duration, target, [touch(...end)])
}

beforeEach(() => {
  document.body.innerHTML = '<div data-view-mode="document"><creative-tree-row><span>Body</span></creative-tree-row></div>'
  root = document.body.firstElementChild
  row = root.firstElementChild
  row.linkUrl = '/creatives/8'
  body = row.firstElementChild
  window.matchMedia = jest.fn(() => ({ matches: true }))
  window.Turbo = { visit: jest.fn() }
  jest.spyOn(window, 'getSelection').mockReturnValue({ isCollapsed: true })
  detach = attachDocumentRowSwipe(root)
})
afterEach(() => { detach(); jest.restoreAllMocks(); delete window.Turbo })

test('left swipe navigates on release and preserves subsequent clicks', () => {
  send('touchstart', [touch(250, 100)])
  send('touchmove', [touch(150, 102)])
  expect(window.Turbo.visit).not.toHaveBeenCalled()
  send('touchend', [], 300, body, [touch(140, 103)])
  expect(window.Turbo.visit).toHaveBeenCalledWith('/creatives/8', undefined)
  const clicked = jest.fn()
  body.addEventListener('click', clicked)
  body.click()
  expect(clicked).toHaveBeenCalledTimes(1)
})

test.each([
  { move: [240, 150], end: [100, 150] },
  { move: [200, 120], end: [100, 120] },
  { move: [280, 100], end: [350, 100] },
  { move: [245, 102], end: [240, 102] },
  { move: [190, 101], end: [180, 101] },
  { end: [100, 130] },
  { end: [170, 125] },
  { duration: 800 }
])('rejects scrolling, diagonal, rightward, short and slow gestures: %j', options => {
  swipe(options)
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test.each(['a', 'button', 'input', 'textarea', 'select', 'video', 'audio', 'img', 'iframe', 'pre', 'table'])('ignores %s', tag => {
  const control = document.createElement(tag)
  body.appendChild(control)
  swipe({ target: control })
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test.each(['desktop', 'tree', 'title', 'select', 'ancestor-select', 'selection', 'editor'])('ignores unavailable state: %s', state => {
  if (state === 'desktop') window.matchMedia.mockReturnValue({ matches: false })
  if (state === 'tree') delete root.dataset.viewMode
  if (state === 'title') row.isTitle = true
  if (state === 'select') row.selectMode = true
  if (state === 'ancestor-select') root.setAttribute('data-select-mode-active', '')
  if (state === 'selection') window.getSelection.mockReturnValue({ isCollapsed: false })
  if (state === 'editor') document.body.insertAdjacentHTML('beforeend', '<form id="inline-edit-form"></form>')
  swipe()
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test.each(['multistart', 'multimove', 'cancel', 'identifier', 'missing-end', 'remaining-touch', 'mode-change', 'no-move'])('cancels invalid gesture: %s', state => {
  send('touchstart', state === 'multistart' ? [touch(250, 100), touch(260, 100, 2)] : [touch(250, 100)])
  if (state !== 'no-move') send('touchmove', state === 'multimove' ? [touch(150, 100), touch(160, 100, 2)] : [touch(150, 100, state === 'identifier' ? 2 : 1)])
  if (state === 'cancel') send('touchcancel', [])
  if (state === 'mode-change') delete root.dataset.viewMode
  send('touchend', state === 'remaining-touch' ? [touch(140, 100, 2)] : [], 300, body, state === 'missing-end' ? [] : [touch(140, 100)])
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test('supports read-only rows, hidden editor and workspace frame navigation', () => {
  row.canWrite = false
  document.body.insertAdjacentHTML('beforeend', '<form id="inline-edit-form" style="display:none"></form>')
  const frame = document.createElement('turbo-frame')
  frame.id = 'creative-workspace-content'
  document.body.appendChild(frame)
  frame.appendChild(root)
  swipe()
  expect(window.Turbo.visit).toHaveBeenCalledWith('/creatives/8', { action: 'advance', frame: frame.id })
})

test('cleanup removes listeners and a new touch allows ordinary clicks', () => {
  swipe()
  send('touchstart', [touch(250, 100)])
  const clicked = jest.fn()
  body.addEventListener('click', clicked)
  body.click()
  expect(clicked).toHaveBeenCalledTimes(1)
  window.Turbo.visit.mockClear()
  detach()
  swipe()
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test('ignores touches outside a row and works without selection API', () => {
  swipe({ target: root })
  expect(window.Turbo.visit).not.toHaveBeenCalled()
  window.getSelection.mockReturnValue(null)
  swipe()
  expect(window.Turbo.visit).toHaveBeenCalledTimes(1)
})

test.each(['code.lexical-code-block', '.mermaid-chart', '.lexical-table-wrapper'])('ignores horizontal scroll area %s and its descendants', selector => {
  const container = document.createElement(selector.startsWith('code') ? 'code' : 'div')
  container.className = selector.split('.').pop()
  body.appendChild(container)
  swipe({ target: container })
  const child = document.createElement('span')
  container.appendChild(child)
  swipe({ target: child })
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test.each([23, 0])('ignores swipes starting %spx from the right edge', inset => {
  const x = window.innerWidth - inset
  swipe({ start: [x, 100], move: [x - 100, 102], end: [x - 110, 103] })
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})

test('allows swipes starting at the 24px right edge boundary', () => {
  const x = window.innerWidth - 24
  swipe({ start: [x, 100], move: [x - 100, 102], end: [x - 110, 103] })
  expect(window.Turbo.visit).toHaveBeenCalledTimes(1)
})

test.each(['wrapper', 'toolbar'])('ignores rendered table %s outside the table itself', targetType => {
  const wrapper = document.createElement('div')
  wrapper.className = 'table-download-wrapper'
  wrapper.innerHTML = '<div class="table-download-toolbar"><button>Download</button></div><table><tbody><tr><td>Cell</td></tr></tbody></table>'
  body.appendChild(wrapper)
  const target = targetType === 'wrapper' ? wrapper : wrapper.firstElementChild
  swipe({ target })
  expect(window.Turbo.visit).not.toHaveBeenCalled()
})
