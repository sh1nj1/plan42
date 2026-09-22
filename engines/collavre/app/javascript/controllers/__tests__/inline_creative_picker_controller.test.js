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
  browse.mockResolvedValue([{ id: 7, origin_id: 70, description: 'Destination', has_children: false }])
  search.mockResolvedValue([{ id: 8, description: 'Search result' }])
  document.body.innerHTML = `<div data-controller="inline-creative-picker"
    data-action="focusout->inline-creative-picker#closeOnFocusOut"
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

test('opens below the existing input, keeps focus, and selects the shell id', async () => {
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
