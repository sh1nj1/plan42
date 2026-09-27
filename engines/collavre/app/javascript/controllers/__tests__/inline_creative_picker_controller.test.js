/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const browse = jest.fn()
const search = jest.fn()
jest.unstable_mockModule('../../lib/api/creatives', () => ({ default: { browse, search } }))
const { default: Picker } = await import('../inline_creative_picker_controller')
const flush = () => new Promise(resolve => setTimeout(resolve, 0))
let app, picker, input, list, select, close

beforeEach(async () => {
  jest.clearAllMocks()
  HTMLElement.prototype.showPopover = jest.fn()
  HTMLElement.prototype.hidePopover = jest.fn()
  browse.mockResolvedValue([{ id: 7, origin_id: 70, description: 'Destination', has_children: false }])
  search.mockResolvedValue([{ id: 8, description: 'Search result' }])
  document.body.innerHTML = `<div data-controller="inline-creative-picker"
    data-action="focusout->inline-creative-picker#closeOnFocusOut keydown->inline-creative-picker#handleEscape"
    data-link-creative-loading-text="Loading" data-link-creative-empty-text="Empty">
    <input data-inline-creative-picker-target="input"
      data-action="input->inline-creative-picker#_debouncedSearch keydown->inline-creative-picker#handleInputKeydown">
    <ul data-inline-creative-picker-target="list" hidden></ul></div><button id="outside">Other</button>`
  app = Application.start()
  app.register('inline-creative-picker', Picker)
  await flush()
  picker = app.getControllerForElementAndIdentifier(document.querySelector('div'), 'inline-creative-picker')
  input = picker.inputTarget
  list = picker.listTarget
  select = jest.fn()
  close = jest.fn()
  Object.defineProperty(HTMLElement.prototype, 'offsetParent', { configurable: true, get() { return this.parentNode } })
  HTMLElement.prototype.scrollIntoView = jest.fn()
})
afterEach(() => { picker.disconnect(); app.stop(); document.body.innerHTML = '' })
const open = async () => { input.focus(); picker.open(null, select, close); await flush() }
const key = value => {
  const event = new KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true })
  input.dispatchEvent(event)
  return event
}

test('floats below the existing input, keeps focus, and selects the shell id', async () => {
  await open()
  expect(list.hidden).toBe(false)
  expect(input.getAttribute('aria-expanded')).toBe('true')
  expect(document.activeElement).toBe(input)
  key('ArrowDown')
  expect(picker._navigated).toBe(true)
  expect(key('Enter').defaultPrevented).toBe(true)
  expect(select).toHaveBeenCalledWith({ id: 7, label: 'Destination' })
  expect(list.hidden).toBe(true)
  expect(close).toHaveBeenCalledTimes(1)
  expect(input.getAttribute('aria-expanded')).toBe('false')
})

test('Escape dismisses results without bubbling to the dialog, then passes through', async () => {
  await open()
  const listener = jest.fn()
  document.body.addEventListener('keydown', listener)
  expect(key('Escape').defaultPrevented).toBe(true)
  expect(listener).not.toHaveBeenCalled()
  expect(key('Escape').defaultPrevented).toBe(false)
  expect(listener).toHaveBeenCalledTimes(1)
  document.body.removeEventListener('keydown', listener)
})

test('focus leaving the field closes results, but focus within the field does not', async () => {
  await open()
  picker.closeOnFocusOut({ relatedTarget: list })
  expect(list.hidden).toBe(false)
  document.getElementById('outside').focus()
  expect(list.hidden).toBe(true)
})

test.each(['close', 'disconnect'])('ignores a pending search after %s', async action => {
  await open()
  let resolve
  search.mockReturnValueOnce(new Promise(done => { resolve = done }))
  input.value = 'query'
  picker.search()
  picker[action]()
  resolve([{ id: 9, description: 'Late result' }])
  await flush()
  expect(list.hidden).toBe(true)
  expect(list.textContent).not.toContain('Late result')
})

test('typing debounces searches and closing cancels the timer', async () => {
  await open()
  jest.useFakeTimers()
  input.value = 'query'
  input.dispatchEvent(new Event('input', { bubbles: true }))
  jest.advanceTimersByTime(300)
  expect(search).toHaveBeenCalledWith('query', { simple: true })
  input.dispatchEvent(new Event('input', { bubbles: true }))
  picker.close()
  jest.advanceTimersByTime(300)
  expect(search).toHaveBeenCalledTimes(1)
  jest.useRealTimers()
})

test('Enter cannot submit while there are no selectable results', async () => {
  browse.mockResolvedValue([])
  await open()
  expect(key('Enter').defaultPrevented).toBe(true)
  expect(select).not.toHaveBeenCalled()
  expect(list.textContent).toBe('Empty')
})


test('positions below the input and tracks viewport and scroll changes', async () => {
  input.getBoundingClientRect = () => ({ left: 20, top: 250, bottom: 280, width: 300 })
  await open()
  expect(list.showPopover).toHaveBeenCalled()
  expect(list.style.top).toBe('284px')
  expect(list.style.transform).toBe('')
  expect(list.style.width).toBe('300px')
  expect(list.style.maxHeight).toBe('320px')
  input.getBoundingClientRect = () => ({ left: -20, top: 150, bottom: 180, width: 300 })
  window.dispatchEvent(new Event('scroll'))
  expect(list.style.left).toBe('8px')
  expect(list.style.top).toBe('184px')
  picker.close()
  window.dispatchEvent(new Event('resize'))
  picker._reposition()
  expect(list.style.top).toBe('184px')
  expect(list.hidePopover).toHaveBeenCalled()
})

test('Escape from a tree button closes only the results and restores input focus', async () => {
  browse.mockResolvedValue([{ id: 7, description: 'Parent', has_children: true }])
  await open()
  const button = list.querySelector('button')
  button.focus()
  const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })
  button.dispatchEvent(event)
  expect(event.defaultPrevented).toBe(true)
  expect(list.hidden).toBe(true)
  expect(document.activeElement).toBe(input)
})


test('repositions within a resized visual viewport and removes its listeners on close', async () => {
  const viewport = new EventTarget()
  Object.assign(viewport, { offsetTop: 40, offsetLeft: 10, width: 280, height: 400 })
  Object.defineProperty(window, 'visualViewport', { configurable: true, value: viewport })
  input.getBoundingClientRect = () => ({ left: 200, top: 180, bottom: 210, width: 400 })
  await open()
  expect(list.style.width).toBe('264px')
  expect(list.style.left).toBe('18px')
  expect(list.style.maxHeight).toBe('218px')
  viewport.offsetTop = 60
  viewport.dispatchEvent(new Event('resize'))
  expect(list.style.maxHeight).toBe('238px')
  viewport.offsetTop = 80
  viewport.dispatchEvent(new Event('scroll'))
  expect(list.style.maxHeight).toBe('258px')
  picker.close()
  viewport.offsetTop = 100
  viewport.dispatchEvent(new Event('resize'))
  expect(list.style.maxHeight).toBe('258px')
  delete window.visualViewport
})

test.each([true, false])('keeps results usable in a short viewport (popover: %s)', async popover => {
  if (!popover) {
    delete HTMLElement.prototype.showPopover
    delete HTMLElement.prototype.hidePopover
  }
  const dialog = document.createElement('dialog')
  document.body.append(dialog)
  dialog.append(picker.element)
  await flush()
  dialog.style.top = '150px'
  dialog.getBoundingClientRect = () => ({ top: parseFloat(dialog.style.top) })
  input.getBoundingClientRect = () => {
    const top = parseFloat(dialog.style.top) + 100
    return { left: 20, top, bottom: top + 30, height: 30, width: 300 }
  }
  const viewport = new EventTarget()
  Object.assign(viewport, { offsetTop: 0, offsetLeft: 0, width: 390, height: 280 })
  Object.defineProperty(window, 'visualViewport', { configurable: true, value: viewport })
  try {
    await open()
    expect(list.style.maxHeight).toBe('120px')
    expect(parseFloat(list.style.top)).toBe(input.getBoundingClientRect().bottom + 4)
    expect(parseFloat(list.style.top) + 120).toBeLessThanOrEqual(272)
    viewport.offsetTop = 200
    viewport.dispatchEvent(new Event('scroll'))
    expect(input.getBoundingClientRect().top).toBeGreaterThanOrEqual(208)
    expect(parseFloat(list.style.maxHeight)).toBeGreaterThanOrEqual(120)
    viewport.height = 100
    viewport.dispatchEvent(new Event('resize'))
    expect(list.style.maxHeight).toBe('50px')
    expect(parseFloat(list.style.top) + 50).toBeLessThanOrEqual(292)
    key('ArrowDown')
    key('Enter')
    expect(select).toHaveBeenCalledWith({ id: 7, label: 'Destination' })
    expect(dialog.style.top).toBe('150px')
    await open()
    key('Escape')
    expect(dialog.style.top).toBe('150px')
  } finally {
    delete window.visualViewport
  }
})

test('without the Popover API, browsing, searching, selecting and reopening still work', async () => {
  delete HTMLElement.prototype.showPopover
  delete HTMLElement.prototype.hidePopover
  list.setAttribute('popover', 'manual')
  input.getBoundingClientRect = () => ({ left: 20, top: 250, bottom: 280, width: 300 })
  await open()
  expect(list.hasAttribute('popover')).toBe(false)
  expect(list.hidden).toBe(false)
  expect(list.textContent).toContain('Destination')
  expect(list.style.top).toBe('284px')
  input.value = 'query'
  await picker.search()
  expect(list.textContent).toContain('Search result')
  key('ArrowDown')
  key('Enter')
  expect(select).toHaveBeenCalledWith({ id: 8, label: 'Search result' })
  expect(list.hidden).toBe(true)
  input.value = ''
  await open()
  expect(list.hidden).toBe(false)
  expect(key('Escape').defaultPrevented).toBe(true)
  expect(list.hidden).toBe(true)
  expect(close).toHaveBeenCalledTimes(2)
})
