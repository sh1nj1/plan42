/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

await import('../mention_menu')

describe('mention menu routes', () => {
  const originalFetch = global.fetch

  beforeEach(() => {
    jest.useFakeTimers()
    document.body.innerHTML = `
      <form id="new-comment-form"><textarea></textarea></form>
      <div id="comments-popup"
           data-creative-id="7"
           data-user-search-url="/collavre/users/search"></div>
      <div id="mention-menu" style="display:none">
        <ul class="mention-results"></ul>
      </div>
    `
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([]),
    })
  })

  afterEach(() => {
    jest.useRealTimers()
    document.body.innerHTML = ''
    global.fetch = originalFetch
    jest.clearAllMocks()
  })

  test('searches for mention candidates through the engine mount', async () => {
    document.dispatchEvent(new Event('turbo:load'))
    const textarea = document.querySelector('textarea')
    textarea.value = '@agent'
    textarea.setSelectionRange(6, 6)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))

    await jest.advanceTimersByTimeAsync(200)

    const [url, options] = global.fetch.mock.calls[0]
    expect(url.toString()).toBe('http://localhost/collavre/users/search?q=agent&creative_id=7')
    expect(options).toEqual({ headers: { Accept: 'application/json' } })
  })
})
