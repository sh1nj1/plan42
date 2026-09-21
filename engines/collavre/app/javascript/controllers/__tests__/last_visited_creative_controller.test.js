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
    window.localStorage.clear()
    fetchMock = jest.fn().mockImplementation((url) => Promise.resolve(
      url === '/creatives/next_last_visited_sequence'
        ? { ok: true, headers: new Headers(), json: async () => ({ sequence: 2 }) }
        : { ok: true, headers: new Headers() }
    ))
    global.fetch = fetchMock
    document.head.innerHTML = '<meta name="csrf-token" content="token">'
    document.body.innerHTML = `
      <div data-controller="last-visited-creative"
           data-last-visited-creative-url-value="/creatives"
           data-last-visited-creative-creative-id-value="2"
           data-last-visited-creative-visit-token-value="server-token"
           data-last-visited-creative-visit-sequence-value="1"></div>
    `
    application = Application.start()
    application.register('last-visited-creative', LastVisitedCreativeController)
    await new Promise((resolve) => requestAnimationFrame(resolve))
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application?.stop()
    document.head.innerHTML = ''
    document.body.innerHTML = ''
    window.localStorage.clear()
    delete global.fetch
  })

  test('records a cached history restore', async () => {
    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.dispatchEvent(new Event('turbo:render'))

    await new Promise((resolve) => requestAnimationFrame(resolve))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock).toHaveBeenCalledWith('/creatives/2/remember_last_visited?visit_token=server-token', expect.objectContaining({
      method: 'PATCH',
      credentials: 'same-origin',
    }))
    expect(fetchMock.mock.calls[1][1].headers.get('X-Collavre-Last-Visited-Creative-Sequence')).toBe('2')
  })

  test('records a cached history restore after Turbo reconnects the page', async () => {
    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.body.innerHTML = `
      <div data-controller="last-visited-creative"
           data-last-visited-creative-url-value="/creatives"
           data-last-visited-creative-creative-id-value="1"
           data-last-visited-creative-visit-token-value="server-token"
           data-last-visited-creative-visit-sequence-value="1"></div>
    `
    document.dispatchEvent(new Event('turbo:render'))

    await new Promise((resolve) => requestAnimationFrame(resolve))
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock).toHaveBeenCalledWith('/creatives/1/remember_last_visited?visit_token=server-token', expect.objectContaining({
      method: 'PATCH',
      credentials: 'same-origin',
    }))
  })

  test('obtains an ordered visit token from Rails before a Turbo navigation request', async () => {
    const fetchOptions = { method: 'GET', headers: new Headers() }
    const resume = jest.fn()
    const event = new CustomEvent('turbo:before-fetch-request', {
      cancelable: true,
      detail: { fetchOptions, resume, url: '/creatives?id=2' },
    })
    document.dispatchEvent(event)
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(event.defaultPrevented).toBe(true)
    expect(resume).toHaveBeenCalled()
    expect(fetchOptions.headers.get('X-Collavre-Last-Visited-Creative-Token')).toBe('server-token')
    expect(fetchOptions.headers.get('X-Collavre-Last-Visited-Creative-Sequence')).toBe('2')
  })

  test('uses Rails to allocate a restored visit sequence without browser storage', async () => {
    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.dispatchEvent(new Event('turbo:render'))
    await new Promise((resolve) => requestAnimationFrame(resolve))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock).toHaveBeenCalledWith('/creatives/next_last_visited_sequence', expect.objectContaining({ method: 'PATCH' }))
    expect(fetchMock.mock.calls.at(-1)[1].headers.get('X-Collavre-Last-Visited-Creative-Sequence')).toBe('2')
  })
})
