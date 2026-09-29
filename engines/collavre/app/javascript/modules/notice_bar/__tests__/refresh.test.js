/** @jest-environment jsdom */
import { jest } from '@jest/globals'
const fetch = jest.fn()
jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({ default: fetch }))
const NoticeRefresh = (await import('../refresh')).default

describe('notice snooze refresh', () => {
  let refresh, apply
  const deadline = (ms) => new Date(Date.now() + ms).toISOString()
  beforeEach(() => {
    jest.useFakeTimers()
    fetch.mockReset()
    apply = jest.fn()
    refresh = new NoticeRefresh('/user_notices', apply)
  })
  afterEach(() => { refresh.destroy(); jest.useRealTimers() })

  test('uses the earliest deadline and schedules the next server deadline', async () => {
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: deadline(2000) }) })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: ['next'], refresh_at: null }) })
    refresh.schedule(null)
    refresh.schedule('invalid')
    refresh.schedule(deadline(2000))
    refresh.schedule(deadline(1000))
    refresh.schedule(deadline(3000))
    await jest.advanceTimersByTimeAsync(1000)
    expect(apply).toHaveBeenCalledWith([])
    await jest.advanceTimersByTimeAsync(2000)
    expect(apply).toHaveBeenLastCalledWith(['next'])
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  test.each(['offline', 'rejected'])('retries %s without restoring stale items', async (failure) => {
    if (failure === 'offline') fetch.mockRejectedValueOnce(new Error('offline'))
    else fetch.mockResolvedValueOnce({ ok: false })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: null }) })
    refresh.schedule(deadline(-100))
    await jest.advanceTimersByTimeAsync(1000)
    expect(apply).not.toHaveBeenCalled()
    await jest.advanceTimersByTimeAsync(60000)
    expect(apply).toHaveBeenCalledWith([])
  })

  test('backs off repeated past deadlines when the client clock is ahead', async () => {
    const past = deadline(-5000)
    fetch.mockResolvedValue({ ok: true, json: async () => ({ items: [], refresh_at: past }) })
    refresh.schedule(past)
    await jest.advanceTimersByTimeAsync(999)
    expect(fetch).not.toHaveBeenCalled()
    await jest.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(1)
    for (const wait of [2000, 4000, 8000, 16000, 32000, 60000, 60000]) {
      const calls = fetch.mock.calls.length
      await jest.advanceTimersByTimeAsync(wait - 1)
      expect(fetch).toHaveBeenCalledTimes(calls)
      await jest.advanceTimersByTimeAsync(1)
      expect(fetch).toHaveBeenCalledTimes(calls + 1)
    }
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: ['awake'], refresh_at: null }) })
    await jest.advanceTimersByTimeAsync(60000)
    expect(apply).toHaveBeenLastCalledWith(['awake'])
    expect(jest.getTimerCount()).toBe(0)
  })

  test('a different deadline resets the backoff', async () => {
    const past = deadline(-5000)
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: past }) })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: deadline(-100) }) })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: ['awake'], refresh_at: null }) })
    refresh.schedule(past)
    await jest.advanceTimersByTimeAsync(3000)
    expect(fetch).toHaveBeenCalledTimes(2)
    await jest.advanceTimersByTimeAsync(999)
    expect(fetch).toHaveBeenCalledTimes(2)
    await jest.advanceTimersByTimeAsync(1)
    expect(apply).toHaveBeenLastCalledWith(['awake'])
  })

  test('disconnect cancels pending timers', async () => {
    refresh.schedule(deadline(1000))
    refresh.destroy()
    refresh.schedule(deadline(500))
    await jest.advanceTimersByTimeAsync(2000)
    expect(fetch).not.toHaveBeenCalled()
  })

  test('disconnect ignores an in-flight response', async () => {
    let resolve
    fetch.mockReturnValue(new Promise((done) => { resolve = done }))
    refresh.schedule(deadline(0))
    await jest.advanceTimersByTimeAsync(1000)
    refresh.destroy()
    resolve({ ok: true, json: async () => ({ items: ['stale'], refresh_at: deadline(100) }) })
    await jest.advanceTimersByTimeAsync(1000)
    expect(apply).not.toHaveBeenCalled()
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})
