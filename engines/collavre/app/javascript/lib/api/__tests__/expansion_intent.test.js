/** @jest-environment jsdom */
import { jest } from '@jest/globals'

describe('expansion intent allocation', () => {
  beforeEach(() => {
    jest.resetModules()
    localStorage.clear()
  })
  afterEach(() => {
    jest.restoreAllMocks()
    delete navigator.locks
  })

  test('requests the lock immediately and serializes equal-time intents from separate tabs', async () => {
    let locks = Promise.resolve()
    navigator.locks = { request: jest.fn((key, allocate) => {
      locks = locks.then(allocate)
      return locks
    }) }
    jest.spyOn(performance, 'now').mockReturnValue(1)
    const firstTab = await import('../expansion_intent')
    const first = firstTab.reserveExpansionIntent('10')
    expect(navigator.locks.request).toHaveBeenCalledTimes(1)
    jest.resetModules()
    const secondTab = await import('../expansion_intent')
    const second = secondTab.reserveExpansionIntent('10')
    expect(await second).toBe((await first) + 1)
    expect(navigator.locks.request.mock.calls.map(([key]) => key)).toEqual([
      'collavre:expansion-intent:10', 'collavre:expansion-intent:10',
    ])
  })

  test('shared storage survives reload and a backward clock change', async () => {
    localStorage.setItem('collavre:expansion-intent:10', '8000000000000000')
    const { reserveExpansionIntent } = await import('../expansion_intent')
    expect(await reserveExpansionIntent('10')).toBe(8000000000000001)
    expect(await reserveExpansionIntent('10')).toBe(8000000000000002)
  })

  test.each(['bad', 'Infinity', '-1', '1.5'])('ignores malformed persisted clock %s', async value => {
    localStorage.setItem('collavre:expansion-intent:10', value)
    const { reserveExpansionIntent } = await import('../expansion_intent')
    expect(Number.isSafeInteger(await reserveExpansionIntent('10'))).toBe(true)
  })

  test('storage-disabled fallback keeps in-document intents monotonic', async () => {
    jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('disabled') })
    jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('disabled') })
    jest.spyOn(performance, 'now').mockReturnValue(1)
    const { reserveExpansionIntent } = await import('../expansion_intent')
    const first = await reserveExpansionIntent('10')
    expect(await reserveExpansionIntent('10')).toBe(first + 1)
  })
})
