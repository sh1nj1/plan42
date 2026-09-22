/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const response = (body, ok = true) => ({ ok, headers: new Headers(), json: async () => body })
const intent = { creative_id: null, node_id: '1', expanded: true }

describe('server-issued expansion ordering', () => {
  let queueExpansionSave
  beforeEach(async () => {
    jest.resetModules()
    ;({ queueExpansionSave } = await import('../expansion_save_queue'))
    document.body.dataset.currentUserId = '10'
    global.fetch = jest.fn().mockResolvedValue(response({ success: true }))
  })
  afterEach(() => jest.useRealTimers())

  test('hard reload uses the shared server counter for a new document', async () => {
    fetch.mockResolvedValueOnce(response({ expansion_save_fence: 41 }))
    await queueExpansionSave('10', intent)
    const firstCalls = [...fetch.mock.calls]
    jest.resetModules()
    const newDocument = await import('../expansion_save_queue')
    fetch.mockResolvedValueOnce(response({ expansion_save_fence: 42 }))
    await newDocument.queueExpansionSave('10', { ...intent, expanded: false })
    const calls = [...firstCalls, ...fetch.mock.calls]
    expect(calls.map(([url]) => url.split('/').at(-1))).toEqual(['fence', 'toggle', 'fence', 'toggle'])
    const bodies = calls.map(([, options]) => JSON.parse(options.body))
    expect(bodies[1]).toEqual({ ...intent, expected_user_id: '10', expansion_save_fence: 41 })
    expect(bodies[3]).toEqual({ ...intent, expected_user_id: '10', expanded: false, expansion_save_fence: 42 })
  })

  test.each([{}, { expansion_save_fence: 0 }, { expansion_save_fence: '1' }, { expansion_save_fence: 1.5 }])('invalid reservation %j never sends an unfenced toggle', async (body) => {
    fetch.mockResolvedValueOnce(response(body))
    await queueExpansionSave('10', intent)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  test('failed reservation advances the queue without a fallback write', async () => {
    fetch.mockResolvedValueOnce(response({}, false))
      .mockResolvedValueOnce(response({ expansion_save_fence: 2 }))
    queueExpansionSave('10', intent)
    await queueExpansionSave('10', { ...intent, expanded: false })
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(JSON.parse(fetch.mock.calls[2][1].body).expanded).toBe(false)
  })

  test.each(['transport', 'body'])('a stalled reservation %s times out without a late toggle', async (stage) => {
    jest.useFakeTimers()
    let resolve
    const pending = new Promise((done) => { resolve = done })
    fetch.mockImplementationOnce(() => stage === 'transport' ? pending : Promise.resolve({ ...response({}), json: () => pending }))
      .mockResolvedValueOnce(response({ expansion_save_fence: 8 }))
    queueExpansionSave('10', intent)
    const next = queueExpansionSave('10', { ...intent, expanded: false })
    await jest.advanceTimersByTimeAsync(10000)
    await next
    expect(fetch.mock.calls[0][1].signal.aborted).toBe(true)
    expect(fetch).toHaveBeenCalledTimes(3)
    resolve(stage === 'transport' ? response({ expansion_save_fence: 7 }) : { expansion_save_fence: 7 })
    await jest.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(jest.getTimerCount()).toBe(0)
  })

  test('account change during reservation prevents the second request', async () => {
    fetch.mockImplementationOnce(async () => {
      document.body.dataset.currentUserId = '20'
      return response({ expansion_save_fence: 3 })
    })
    await queueExpansionSave('10', intent)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  test.each(['', '20'])('missing or changed user %s is skipped before reservation', async (user) => {
    await queueExpansionSave(user, intent)
    expect(fetch).not.toHaveBeenCalled()
  })
})
