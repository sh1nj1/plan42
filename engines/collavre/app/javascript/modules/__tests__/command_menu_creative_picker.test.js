/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const openCreativeLinkPicker = jest.fn()

jest.unstable_mockModule('../creative_link_picker', () => ({
  openCreativeLinkPicker,
}))

await import('../command_menu')

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('command menu Creative picker', () => {
  const originalFetch = global.fetch

  afterEach(() => {
    document.body.innerHTML = ''
    global.fetch = originalFetch
    jest.clearAllMocks()
  })

  test('routes the /creative command through the shared picker', async () => {
    document.body.innerHTML = `
      <form id="new-comment-form"><textarea>/creative</textarea></form>
      <div id="comments-popup" data-creative-id="7"></div>
      <div id="command-menu" style="display:none">
        <ul data-popup-list></ul>
      </div>
    `
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{
        type: 'popup',
        popup_type: 'creative_picker',
        name: 'creative',
        label: '/creative',
        aliases: [],
      }]),
    })

    document.dispatchEvent(new Event('turbo:load'))
    const textarea = document.querySelector('textarea')
    textarea.setSelectionRange(9, 9)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    await flush()

    textarea.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    }))

    expect(openCreativeLinkPicker).toHaveBeenCalledWith(textarea, {
      triggerRange: { start: 0, end: 9 },
    })
  })
})
