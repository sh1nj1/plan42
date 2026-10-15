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

  test('tapping more toggles on touchend and does not select the item', async () => {
    const { textarea, menu } = await open()
    const button = menu.querySelector('[data-command-more]')
    const touch = (type) => {
      const event = new Event(type, { bubbles: true, cancelable: true })
      event.touches = [{ clientY: 0 }]
      event.changedTouches = [{ clientY: 0 }]
      button.dispatchEvent(event)
      return event
    }

    touch('touchstart')
    const end = touch('touchend')
    expect(end.defaultPrevented).toBe(true)
    expect(menu.querySelector('.command-details').hidden).toBe(false)
    expect(textarea.value).toBe('/')
  })

  test('clicking elsewhere on the item still selects the command', async () => {
    const { textarea, menu } = await open()
    menu.querySelectorAll('.common-popup-item')[1].click()
    expect(textarea.value).toBe('/topic_list ')
  })

  test('falls back to English labels when the menu has none', async () => {
    const { menu } = await open('')
    const button = menu.querySelector('[data-command-more]')
    expect(button.textContent).toBe('More')
    button.click()
    expect(button.textContent).toBe('Less')
  })
})
