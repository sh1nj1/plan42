/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

jest.unstable_mockModule('../creative_link_picker', () => ({
  openCreativeLinkPicker: jest.fn(),
}))

await import('../command_menu')

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

const COMMANDS = [
  { name: 'cron_list', label: '/cron_list', description: '예약 작업 <목록>', details: '자세한 설명' },
  { name: 'topic_list', label: '/topic_list', description: 'List topics' },
]

describe('command menu details toggle', () => {
  const originalFetch = global.fetch

  const open = async (dataset = 'data-more-label="더보기" data-less-label="접기"') => {
    global.fetch = jest.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve(COMMANDS) }))
    document.body.innerHTML = `
      <form id="new-comment-form"><textarea></textarea></form>
      <div id="comments-popup" data-creative-id="7"></div>
      <div id="command-menu" style="display:none" ${dataset}>
        <ul data-popup-list></ul>
      </div>
    `
    document.dispatchEvent(new Event('turbo:load'))
    const textarea = document.querySelector('textarea')
    textarea.value = '/'
    textarea.setSelectionRange(1, 1)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    return { textarea, menu: document.getElementById('command-menu') }
  }

  afterEach(() => {
    document.body.innerHTML = ''
    global.fetch = originalFetch
  })

  test('renders the escaped summary with a collapsed details toggle', async () => {
    const { menu } = await open()
    const [first, second] = menu.querySelectorAll('.common-popup-item')

    expect(first.querySelector('.command-description').textContent).toBe('예약 작업 <목록>')
    expect(first.querySelector('.command-description').innerHTML).toContain('&lt;목록&gt;')
    const button = first.querySelector('[data-command-more]')
    expect(button.textContent).toBe('더보기')
    expect(button.getAttribute('aria-expanded')).toBe('false')
    expect(first.querySelector('.command-details').hidden).toBe(true)
    expect(second.querySelector('[data-command-more]')).toBeNull()
  })

  test('clicking more expands and collapses details without choosing the command', async () => {
    const { textarea, menu } = await open()
    const item = menu.querySelector('.common-popup-item')
    const button = item.querySelector('[data-command-more]')
    const details = item.querySelector('.command-details')

    button.click()
    expect(details.hidden).toBe(false)
    expect(button.textContent).toBe('접기')
    expect(button.getAttribute('aria-expanded')).toBe('true')
    expect(textarea.value).toBe('/')
    expect(menu.style.display).toBe('block')

    button.click()
    expect(details.hidden).toBe(true)
    expect(button.textContent).toBe('더보기')
  })

  const touchOn = (button) => (type, clientY) => {
    const event = new Event(type, { bubbles: true, cancelable: true })
    event.touches = [{ clientY }]
    event.changedTouches = [{ clientY }]
    button.dispatchEvent(event)
    return event
  }

  test('tapping more toggles on touchend and does not select the item', async () => {
    const { textarea, menu } = await open()
    const touch = touchOn(menu.querySelector('[data-command-more]'))

    const start = touch('touchstart', 0)
    expect(start.defaultPrevented).toBe(false)
    const end = touch('touchend', 4)
    expect(end.defaultPrevented).toBe(true)
    expect(menu.querySelector('.command-details').hidden).toBe(false)
    expect(textarea.value).toBe('/')
  })

  test('swiping from more scrolls without toggling or selecting the item', async () => {
    const { textarea, menu } = await open()
    const touch = touchOn(menu.querySelector('[data-command-more]'))

    const start = touch('touchstart', 0)
    const end = touch('touchend', 100)
    expect(start.defaultPrevented).toBe(false)
    expect(end.defaultPrevented).toBe(false)
    expect(menu.querySelector('.command-details').hidden).toBe(true)
    expect(textarea.value).toBe('/')
    expect(menu.style.display).toBe('block')
  })

  test('touchend without a matching touchstart does not toggle', async () => {
    const { menu } = await open()
    touchOn(menu.querySelector('[data-command-more]'))('touchend', 0)
    expect(menu.querySelector('.command-details').hidden).toBe(true)
  })

  test('clicking elsewhere on the item still selects the command', async () => {
    const { textarea, menu } = await open()
    menu.querySelectorAll('.common-popup-item')[1].click()
    expect(textarea.value).toBe('/topic_list ')
  })

  const key = (textarea, keyName, init = {}) => {
    const event = new KeyboardEvent('keydown', { key: keyName, bubbles: true, cancelable: true, ...init })
    textarea.dispatchEvent(event)
    return event
  }

  test('ArrowRight/ArrowLeft expand and collapse the active command details from the textarea', async () => {
    const { textarea, menu } = await open()
    const item = menu.querySelector('.common-popup-item')
    const button = item.querySelector('[data-command-more]')
    const details = item.querySelector('.command-details')
    expect(item.classList.contains('active')).toBe(true)

    expect(key(textarea, 'ArrowRight').defaultPrevented).toBe(true)
    expect(details.hidden).toBe(false)
    expect(button.textContent).toBe('접기')
    expect(button.getAttribute('aria-expanded')).toBe('true')
    expect(textarea.value).toBe('/')
    expect(menu.style.display).toBe('block')

    expect(key(textarea, 'ArrowRight').defaultPrevented).toBe(false)
    expect(details.hidden).toBe(false)

    expect(key(textarea, 'ArrowLeft').defaultPrevented).toBe(true)
    expect(details.hidden).toBe(true)
    expect(button.textContent).toBe('더보기')

    expect(key(textarea, 'ArrowLeft').defaultPrevented).toBe(false)
  })

  test('ArrowLeft moves the caret instead of collapsing when it is not at the end', async () => {
    const { textarea, menu } = await open()
    const details = menu.querySelector('.command-details')
    textarea.value = '/ draft'
    textarea.setSelectionRange(7, 7)
    expect(key(textarea, 'ArrowRight').defaultPrevented).toBe(true)
    expect(details.hidden).toBe(false)

    textarea.setSelectionRange(3, 3)
    expect(key(textarea, 'ArrowLeft').defaultPrevented).toBe(false)
    expect(details.hidden).toBe(false)

    textarea.setSelectionRange(3, 7)
    expect(key(textarea, 'ArrowLeft').defaultPrevented).toBe(false)
    expect(details.hidden).toBe(false)

    textarea.setSelectionRange(7, 7)
    expect(key(textarea, 'ArrowLeft').defaultPrevented).toBe(true)
    expect(details.hidden).toBe(true)
  })

  test('arrow keys leave the caret alone when they cannot toggle', async () => {
    const { textarea, menu } = await open()
    const details = menu.querySelector('.command-details')

    expect(key(textarea, 'ArrowRight', { shiftKey: true }).defaultPrevented).toBe(false)
    textarea.value = '/ draft'
    textarea.setSelectionRange(1, 1)
    expect(key(textarea, 'ArrowRight').defaultPrevented).toBe(false)
    expect(details.hidden).toBe(true)

    textarea.setSelectionRange(7, 7)
    key(textarea, 'ArrowDown')
    expect(menu.querySelectorAll('.common-popup-item')[1].classList.contains('active')).toBe(true)
    expect(key(textarea, 'ArrowRight').defaultPrevented).toBe(false)
    expect(key(textarea, 'Escape').defaultPrevented).toBe(false)
    expect(menu.style.display).toBe('none')
    expect(key(textarea, 'ArrowRight').defaultPrevented).toBe(false)
  })

  test('falls back to English labels when the menu has none', async () => {
    const { menu } = await open('')
    const button = menu.querySelector('[data-command-more]')
    expect(button.textContent).toBe('More')
    button.click()
    expect(button.textContent).toBe('Less')
  })
})
