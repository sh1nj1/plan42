/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const csrfFetch = jest.fn()
jest.unstable_mockModule('../../lib/api/csrf_fetch', () => ({ default: csrfFetch }))
const { Application } = await import('@hotwired/stimulus')
const Controller = (await import('../creative_history_detail_controller')).default

describe('CreativeHistoryDetailController', () => {
  let application, element, controller
  const event = () => ({ type: 'toggle', target: element })
  const success = () => ({ ok: true, text: async () => '<table class="diff"></table>' })

  beforeEach(async () => {
    document.body.innerHTML = `<details data-controller="creative-history-detail"
      data-creative-history-detail-url-value="/creatives/1/history/2">
      <div data-creative-history-detail-target="content"></div>
      <p data-creative-history-detail-target="loading" hidden></p>
      <div data-creative-history-detail-target="error" hidden></div>
    </details>`
    application = Application.start()
    application.register('creative-history-detail', Controller)
    await new Promise(resolve => setTimeout(resolve, 0))
    element = document.querySelector('details')
    controller = application.getControllerForElementAndIdentifier(element, 'creative-history-detail')
    csrfFetch.mockReset()
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  test('waits for opening and caches a successful detail within the mounted item', async () => {
    await controller.load(event())
    expect(csrfFetch).not.toHaveBeenCalled()
    element.open = true
    csrfFetch.mockResolvedValue(success())
    await controller.load(event())
    expect(controller.contentTarget.querySelector('table.diff')).not.toBeNull()
    expect(csrfFetch).toHaveBeenCalledWith('/creatives/1/history/2', expect.objectContaining({
      headers: { Accept: 'text/html' }, cache: 'no-store', redirect: 'error',
    }))
    element.open = false
    await controller.load(event())
    element.open = true
    await controller.load(event())
    expect(csrfFetch).toHaveBeenCalledTimes(1)
    expect(controller.loadingTarget.hidden).toBe(true)
  })

  test('ignores nested detail toggles and duplicate requests while loading', async () => {
    element.open = true
    await controller.load({ type: 'toggle', target: controller.contentTarget })
    expect(csrfFetch).not.toHaveBeenCalled()
    let finish
    csrfFetch.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const loading = controller.load(event())
    expect(controller.loadingTarget.hidden).toBe(false)
    await controller.load(event())
    expect(csrfFetch).toHaveBeenCalledTimes(1)
    finish(success())
    await loading
  })

  test.each(['http', 'network'])('allows retry after a %s failure without exposing actions', async failure => {
    element.open = true
    if (failure === 'http') csrfFetch.mockResolvedValueOnce({ ok: false })
    else csrfFetch.mockRejectedValueOnce(new Error('Network failed'))
    await controller.load(event())
    expect(controller.errorTarget.hidden).toBe(false)
    expect(controller.loadingTarget.hidden).toBe(true)
    expect(controller.contentTarget.innerHTML).toBe('')
    csrfFetch.mockResolvedValue(success())
    await controller.load({ type: 'click', target: controller.errorTarget })
    expect(controller.errorTarget.hidden).toBe(true)
    expect(controller.loaded).toBe(true)
  })

  test('aborts on disconnect without displaying a failure', async () => {
    element.open = true
    csrfFetch.mockImplementation((_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
    }))
    const loading = controller.load(event())
    controller.disconnect()
    await loading
    expect(controller.errorTarget.hidden).toBe(true)
    expect(controller.loaded).toBeUndefined()
  })

  test('does not insert a response body that finished after disconnect', async () => {
    element.open = true
    let finish
    csrfFetch.mockResolvedValue({ ok: true, text: () => new Promise(resolve => { finish = resolve }) })
    const loading = controller.load(event())
    await Promise.resolve()
    controller.disconnect()
    finish('<button>Stale approval</button>')
    await loading
    expect(controller.contentTarget.innerHTML).toBe('')
    expect(controller.loaded).toBeUndefined()
  })
})
