/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const csrfFetch = jest.fn()
const confirmDialog = jest.fn()
const alertDialog = jest.fn()

jest.unstable_mockModule('../../lib/api/csrf_fetch', () => ({ default: csrfFetch }))
jest.unstable_mockModule('../../lib/utils/dialog', () => ({ confirmDialog, alertDialog }))

const { Application } = await import('@hotwired/stimulus')
const CreativeHistoryController = (await import('../creative_history_controller')).default

describe('CreativeHistoryController', () => {
  let application
  let controller
  let button

  beforeEach(async () => {
    document.body.innerHTML = `
      <div data-controller="creative-history">
        <button data-action="creative-history#revert"
                data-url="/creatives/1/history/2/revert"
                data-confirm="Revert?"
                data-conflict="Creative #%{id} changed"
                data-force="Force"
                data-skip="Skip">Revert</button>
      </div>`
    application = Application.start()
    application.register('creative-history', CreativeHistoryController)
    await new Promise((resolve) => setTimeout(resolve, 0))
    const element = document.querySelector('[data-controller="creative-history"]')
    controller = application.getControllerForElementAndIdentifier(element, 'creative-history')
    button = document.querySelector('button')
  })

  afterEach(() => {
    application.stop()
    jest.clearAllMocks()
    document.body.innerHTML = ''
  })

  test('collects a force or skip resolution for every conflict', async () => {
    confirmDialog.mockResolvedValueOnce(true).mockResolvedValueOnce(true).mockResolvedValueOnce(false)
    csrfFetch
      .mockResolvedValueOnce({ ok: false, status: 409, json: async () => ({ conflicts: [
        { creative_id: 11 }, { creative_id: 12 },
      ] }) })
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({ status: 'applied' }) })
    const reload = jest.fn()
    jest.spyOn(controller, 'listController', 'get').mockReturnValue({ loadInitialComments: reload })

    await controller.revert({ currentTarget: button })

    expect(JSON.parse(csrfFetch.mock.calls[1][1].body).resolutions).toEqual({
      11: 'force',
      12: 'skip',
    })
    expect(reload).toHaveBeenCalled()
    expect(alertDialog).not.toHaveBeenCalled()
  })

  test('leaves the button enabled when the user cancels', async () => {
    confirmDialog.mockResolvedValue(false)

    await controller.revert({ currentTarget: button })

    expect(csrfFetch).not.toHaveBeenCalled()
    expect(button.disabled).toBe(false)
  })

  test('shows an error and re-enables the button when the request fails', async () => {
    confirmDialog.mockResolvedValue(true)
    csrfFetch.mockResolvedValue({ ok: false, status: 422, json: async () => ({ message: 'Not allowed' }) })

    await controller.revert({ currentTarget: button })

    expect(alertDialog).toHaveBeenCalledWith('Not allowed')
    expect(button.disabled).toBe(false)
  })

  test('reports a partial revert and reloads the remaining changes', async () => {
    confirmDialog.mockResolvedValue(true)
    csrfFetch.mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ status: 'partial', message: 'Some changes remain' }),
    })
    const reload = jest.fn()
    jest.spyOn(controller, 'listController', 'get').mockReturnValue({ loadInitialComments: reload })

    await controller.revert({ currentTarget: button })

    expect(alertDialog).toHaveBeenCalledWith('Some changes remain')
    expect(reload).toHaveBeenCalled()
  })

  test('returns no list controller outside a comments list', () => {
    expect(controller.listController).toBeNull()
  })
})
