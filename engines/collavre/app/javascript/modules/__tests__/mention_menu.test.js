/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const popup = {
  handleKey: () => false,
  hide: jest.fn(),
  setItems: jest.fn(),
  showAt: jest.fn(),
}

jest.unstable_mockModule('../../lib/common_popup', () => ({ default: jest.fn(() => popup) }))
jest.unstable_mockModule('../../utils/caret_position', () => ({ getCaretClientRect: () => null }))

await import('../mention_menu')

describe('mention menu', () => {
  const originalFetch = global.fetch

  beforeEach(() => {
    jest.useFakeTimers()
    document.body.innerHTML = `
      <form id="new-comment-form"><textarea></textarea></form>
      <div id="comments-popup" data-creative-id="42" data-user-search-url="/collavre/users/search"></div>
      <div id="mention-menu"><div class="mention-results"></div></div>
    `
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => [] })
    document.dispatchEvent(new Event('turbo:load'))
  })

  afterEach(() => {
    jest.useRealTimers()
    document.body.innerHTML = ''
    global.fetch = originalFetch
    jest.clearAllMocks()
  })

  test('searches through the request-aware user search URL', async () => {
    const textarea = document.querySelector('textarea')
    textarea.value = '@helper'
    textarea.setSelectionRange(textarea.value.length, textarea.value.length)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))

    await jest.advanceTimersByTimeAsync(200)

    expect(String(global.fetch.mock.calls[0][0])).toBe(
      'http://localhost/collavre/users/search?q=helper&creative_id=42'
    )
  })
})
