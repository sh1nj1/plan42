/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const csrfFetch = jest.fn()
const alertDialog = jest.fn(() => Promise.resolve())

jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({
  default: csrfFetch,
}))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({
  alertDialog,
}))

const { Application } = await import('@hotwired/stimulus')
const WriteAccessRequestController = (await import('../write_access_request_controller')).default

describe('CreativesWriteAccessRequestController', () => {
  const failureMessage = '권한을 요청하지 못했습니다.'
  let application
  let container
  let button

  function markup() {
    return `
      <div data-controller="creatives--write-access-request" data-creatives--write-access-request-url-value="/creatives/1/request_permission" data-creatives--write-access-request-failure-message-value="${failureMessage}">
        <button type="button" data-creatives--write-access-request-target="button" data-action="click->creatives--write-access-request#request">Request write access</button>
        <span data-creatives--write-access-request-target="pending" hidden>Access requested</span>
      </div>
    `
  }

  beforeEach(() => {
    csrfFetch.mockReset()
    alertDialog.mockClear()
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
    expect(alertDialog).toHaveBeenCalledWith(failureMessage)
  })

  test('on network error, re-enables the button', async () => {
    csrfFetch.mockRejectedValue(new Error('network down'))

    button.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(button.hidden).toBe(false)
    expect(button.disabled).toBe(false)
    expect(alertDialog).toHaveBeenCalledWith(failureMessage)
  })

  test('does not fall back to hardcoded copy when no localized failure message is rendered', async () => {
    container.removeAttribute('data-creatives--write-access-request-failure-message-value')
    csrfFetch.mockResolvedValue({ ok: false })

    button.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(button.disabled).toBe(false)
    expect(alertDialog).not.toHaveBeenCalled()
  })

  test('on a followed redirect to the sign-in page (expired session), navigates there instead of showing pending', async () => {
    // fetch() follows redirects by default, so when the session has expired,
    // Authentication#request_authentication redirects to the sign-in page and
    // the browser lands on a 200 OK response for the login form itself. `ok`
    // is therefore true even though no permission request was ever created —
    // `redirected` is what actually distinguishes this from a real success.
    const redirectSpy = jest
      .spyOn(WriteAccessRequestController.prototype, 'redirectToSignIn')
      .mockImplementation(() => {})

    csrfFetch.mockResolvedValue({ ok: true, redirected: true, url: 'http://localhost/session/new' })

    button.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(redirectSpy).toHaveBeenCalledWith('http://localhost/session/new')
    expect(button.hidden).toBe(false)
    const pending = container.querySelector('[data-creatives--write-access-request-target="pending"]')
    expect(pending.hidden).toBe(true)

    redirectSpy.mockRestore()
  })
})
