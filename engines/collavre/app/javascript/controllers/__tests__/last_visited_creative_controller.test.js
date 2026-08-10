/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import LastVisitedCreativeController from '../last_visited_creative_controller'

describe('LastVisitedCreativeController', () => {
  let application
  let fetchMock

  beforeEach(async () => {
    fetchMock = jest.fn().mockResolvedValue({ ok: true, headers: new Headers() })
    global.fetch = fetchMock
    document.head.innerHTML = '<meta name="csrf-token" content="token">'
    document.body.innerHTML = `
      <div data-controller="last-visited-creative"
           data-last-visited-creative-url-value="/creatives"
           data-last-visited-creative-creative-id-value="2"
           data-last-visited-creative-visit-token-value="server-token"></div>
    `
    application = Application.start()
    application.register('last-visited-creative', LastVisitedCreativeController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application?.stop()
    document.head.innerHTML = ''
    document.body.innerHTML = ''
    delete global.fetch
  })

  test('records a cached history restore', async () => {
    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.dispatchEvent(new Event('turbo:render'))

    await new Promise((resolve) => requestAnimationFrame(resolve))

    expect(fetchMock).toHaveBeenCalledWith('/creatives/2/remember_last_visited?visit_token=server-token', expect.objectContaining({
      method: 'PATCH',
      credentials: 'same-origin',
    }))
  })

  test('records a cached history restore after Turbo reconnects the page', async () => {
    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.body.innerHTML = `
      <div data-controller="last-visited-creative"
           data-last-visited-creative-url-value="/creatives"
           data-last-visited-creative-creative-id-value="1"
           data-last-visited-creative-visit-token-value="server-token"></div>
    `
    document.dispatchEvent(new Event('turbo:render'))

    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => requestAnimationFrame(resolve))

    expect(fetchMock).toHaveBeenCalledWith('/creatives/1/remember_last_visited?visit_token=server-token', expect.objectContaining({
      method: 'PATCH',
      credentials: 'same-origin',
    }))
  })
})
