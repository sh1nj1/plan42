/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const csrfFetch = jest.fn()

jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({
  default: csrfFetch,
}))

const { Application } = await import('@hotwired/stimulus')
const WriteAccessRequestController = (await import('../write_access_request_controller')).default

describe('CreativesWriteAccessRequestController', () => {
  let application
  let container
  let button

  function markup() {
    return `
      <div data-controller="creatives--write-access-request" data-creatives--write-access-request-url-value="/creatives/1/request_permission">
        <button type="button" data-creatives--write-access-request-target="button" data-action="click->creatives--write-access-request#request">Request write access</button>
        <span data-creatives--write-access-request-target="pending" hidden>Access requested</span>
      </div>
    `
  }

  beforeEach(() => {
    csrfFetch.mockReset()
    document.body.innerHTML = markup()
    container = document.querySelector('[data-controller="creatives--write-access-request"]')
    button = container.querySelector('[data-creatives--write-access-request-target="button"]')

    application = Application.start()
    application.register('creatives--write-access-request', WriteAccessRequestController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  test('on success, hides the button and shows the pending pill', async () => {
    csrfFetch.mockResolvedValue({ ok: true })

    button.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(csrfFetch).toHaveBeenCalledWith('/creatives/1/request_permission', { method: 'POST' })
    expect(button.hidden).toBe(true)
    const pending = container.querySelector('[data-creatives--write-access-request-target="pending"]')
    expect(pending.hidden).toBe(false)
  })

  test('on non-ok response, re-enables the button and does not show the pending pill', async () => {
    csrfFetch.mockResolvedValue({ ok: false })

    button.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(button.hidden).toBe(false)
    expect(button.disabled).toBe(false)
    const pending = container.querySelector('[data-creatives--write-access-request-target="pending"]')
    expect(pending.hidden).toBe(true)
  })

  test('on network error, re-enables the button', async () => {
    csrfFetch.mockRejectedValue(new Error('network down'))

    button.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(button.hidden).toBe(false)
    expect(button.disabled).toBe(false)
  })
})
