/** @jest-environment jsdom */
import { jest } from '@jest/globals'

await import('../mention_menu')

const users = [{ id: 1, name: 'Alice', avatar_url: '/alice.png' }]
const response = (items = users) => ({ ok: true, json: async () => items })
const flush = async () => { for (let i = 0; i < 6; i++) await Promise.resolve() }
let textarea
const originalFetch = global.fetch

function input(value) {
  textarea.value = value
  textarea.setSelectionRange(value.length, value.length)
  textarea.dispatchEvent(new Event('input', { bubbles: true }))
}

beforeEach(() => {
  jest.useFakeTimers()
  document.body.innerHTML = `
    <form id="new-comment-form"><textarea></textarea></form>
    <div id="comments-popup" data-creative-id="7"></div>
    <div id="mention-menu" style="display:none"><ul class="mention-results"></ul></div>`
  textarea = document.querySelector('textarea')
  global.fetch = jest.fn().mockResolvedValue(response())
  document.dispatchEvent(new Event('turbo:load'))
})

afterEach(() => {
  document.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
  jest.clearAllTimers()
  jest.useRealTimers()
  global.fetch = originalFetch
  document.body.innerHTML = ''
})

test('bare @ immediately requests all mentionable users and allows selection', async () => {
  input('@')
  expect(fetch).toHaveBeenCalledTimes(1)
  const url = fetch.mock.calls[0][0]
  expect(url.searchParams.get('q')).toBe('')
  expect(url.searchParams.get('creative_id')).toBe('7')
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('block')
  expect(document.querySelector('.mention-results').textContent).toContain('Alice')
  textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }))
  expect(textarea.value).toBe('@Alice: ')
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test('name search stays debounced and backspacing to @ immediately reloads the list', async () => {
  input('@Ali')
  expect(fetch).not.toHaveBeenCalled()
  await jest.advanceTimersByTimeAsync(200)
  expect(fetch.mock.calls[0][0].searchParams.get('q')).toBe('Ali')
  input('@')
  expect(fetch).toHaveBeenCalledTimes(2)
  expect(fetch.mock.calls[1][0].searchParams.get('q')).toBe('')
})

test('removing @ cancels a pending search', async () => {
  input('@Ali')
  input('Hello')
  await jest.advanceTimersByTimeAsync(200)
  expect(fetch).not.toHaveBeenCalled()
})

test.each(['', '@Bob'])('ignores a previous response after input changes to %s', async (value) => {
  let resolve
  fetch.mockReturnValueOnce(new Promise((done) => { resolve = done }))
  input('@')
  input(value)
  resolve(response())
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test('ignores results after switching creatives', async () => {
  input('@')
  document.querySelector('#comments-popup').dataset.creativeId = '8'
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test.each([[], null])('hides empty results: %s', async (items) => {
  fetch.mockResolvedValue(response(items))
  input('@')
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test('handles failed requests', async () => {
  fetch.mockRejectedValueOnce(new Error('offline'))
  input('@')
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test('non-success responses leave the menu hidden', async () => {
  fetch.mockResolvedValue({ ok: false })
  input('@')
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test('supports missing creative context without adding a creative id', async () => {
  document.querySelector('#comments-popup').remove()
  document.querySelector('textarea').replaceWith(document.createElement('textarea'))
  textarea = document.querySelector('textarea')
  document.dispatchEvent(new Event('turbo:load'))
  input('@')
  await flush()
  expect(fetch.mock.calls[0][0].searchParams.has('creative_id')).toBe(false)
})

test('leaves ordinary keyboard input alone', () => {
  const event = new KeyboardEvent('keydown', { key: 'a', cancelable: true })
  textarea.dispatchEvent(event)
  expect(event.defaultPrevented).toBe(false)
})

test('initialization tolerates pages without the chat', () => {
  document.body.innerHTML = ''
  document.dispatchEvent(new Event('turbo:load'))
  expect(fetch).not.toHaveBeenCalled()
})

test('keeps the menu visible while a new mention search is debounced and loading', async () => {
  input('@Al')
  await jest.advanceTimersByTimeAsync(200)
  const menu = document.querySelector('#mention-menu')
  expect(menu.style.display).toBe('block')
  let resolve
  fetch.mockReturnValueOnce(new Promise((done) => { resolve = done }))
  input('@Ali')
  expect(menu.style.display).toBe('block')
  await jest.advanceTimersByTimeAsync(200)
  expect(menu.style.display).toBe('block')
  resolve(response([{ id: 2, name: 'Alina', avatar_url: '/alina.png' }]))
  await flush()
  expect(menu.style.display).toBe('block')
  expect(menu.textContent).toContain('Alina')
  input('Hello')
  expect(menu.style.display).toBe('none')
})


test('renders profile HTML and avatar attribute injection as literal data', async () => {
  const name = '<img src=x onerror="alert(1)"> & "Alice"'
  const avatarUrl = '/avatar.png" onerror="alert(2)'
  fetch.mockResolvedValue(response([{ id: 2, name, avatar_url: avatarUrl }]))
  input('@')
  await flush()
  const item = document.querySelector('.mention-item')
  expect(item.textContent).toBe(` ${name}`)
  expect(item.querySelectorAll('img')).toHaveLength(1)
  expect(item.querySelector('img').getAttribute('src')).toBe(avatarUrl)
  expect(item.querySelector('[onerror]')).toBeNull()
  textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }))
  expect(textarea.value).toBe(`@${name}: `)
})

test.each(['network', 'json'])('hides previous suggestions when the current %s request fails', async (failure) => {
  input('@Ali')
  await jest.advanceTimersByTimeAsync(200)
  expect(document.querySelector('#mention-menu').style.display).toBe('block')
  if (failure === 'network') fetch.mockRejectedValueOnce(new Error('offline'))
  else fetch.mockResolvedValueOnce({ ok: true, json: async () => { throw new Error('invalid JSON') } })
  input('@')
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('none')
})

test.each(['input', 'creative'])('ignores a rejected request after the %s changes', async (change) => {
  input('@')
  await flush()
  let reject
  fetch.mockReturnValueOnce(new Promise((resolve, fail) => { reject = fail }))
  input('@A')
  await jest.advanceTimersByTimeAsync(200)
  if (change === 'input') {
    input('@Bob')
    await jest.advanceTimersByTimeAsync(200)
  } else {
    document.querySelector('#comments-popup').dataset.creativeId = '8'
  }
  reject(new Error('offline'))
  await flush()
  expect(document.querySelector('#mention-menu').style.display).toBe('block')
})
