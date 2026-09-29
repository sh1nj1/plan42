/** @jest-environment jsdom */
import { jest } from '@jest/globals'
const fetch = jest.fn()
jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({ default: fetch }))
const NoticeRefresh = (await import('../refresh')).default

describe('notice deadline refresh', () => {
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
    expect(apply).toHaveBeenCalledWith([], expect.any(Function))
    await jest.advanceTimersByTimeAsync(2000)
    expect(apply).toHaveBeenLastCalledWith(['next'], expect.any(Function))
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  test('refreshes at start and end boundaries without navigation', async () => {
    const endsAt = deadline(3000)
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: ['scheduled'], refresh_at: endsAt }) })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: null }) })
    refresh.schedule(deadline(1000))
    await jest.advanceTimersByTimeAsync(1000)
    expect(apply).toHaveBeenLastCalledWith(['scheduled'], expect.any(Function))
    await jest.advanceTimersByTimeAsync(1999)
    expect(fetch).toHaveBeenCalledTimes(1)
    await jest.advanceTimersByTimeAsync(1)
    expect(apply).toHaveBeenLastCalledWith([], expect.any(Function))
    expect(jest.getTimerCount()).toBe(0)
  })

  test('caps distant windows to prevent browser timer overflow', async () => {
    const future = deadline(2147483647 + 10000)
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: future }) })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: ['scheduled'], refresh_at: null }) })
    refresh.schedule(future)
    await jest.advanceTimersByTimeAsync(2147483646)
    expect(fetch).not.toHaveBeenCalled()
    await jest.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(1)
    await jest.advanceTimersByTimeAsync(9999)
    expect(fetch).toHaveBeenCalledTimes(1)
    await jest.advanceTimersByTimeAsync(1)
    expect(apply).toHaveBeenLastCalledWith(['scheduled'], expect.any(Function))
  })

  test.each(['offline', 'rejected'])('retries %s without restoring stale items', async (failure) => {
    if (failure === 'offline') fetch.mockRejectedValueOnce(new Error('offline'))
    else fetch.mockResolvedValueOnce({ ok: false })
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: null }) })
    refresh.schedule(deadline(-100))
    await jest.advanceTimersByTimeAsync(1000)
    expect(apply).not.toHaveBeenCalled()
    await jest.advanceTimersByTimeAsync(60000)
    expect(apply).toHaveBeenCalledWith([], expect.any(Function))
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
    expect(apply).toHaveBeenLastCalledWith(['awake'], expect.any(Function))
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
    expect(apply).toHaveBeenLastCalledWith(['awake'], expect.any(Function))
  })

  test('invalidation while JSON is loading preserves the newer deadline', async () => {
    let resolve
    fetch.mockResolvedValueOnce({ ok: true, json: () => new Promise((done) => { resolve = done }) })
    const request = refresh.refresh()
    await Promise.resolve()
    refresh.invalidate()
    const next = deadline(5000)
    refresh.schedule(next)
    resolve({ items: ['stale'], refresh_at: deadline(1000) })
    await request
    expect(apply).not.toHaveBeenCalled()
    expect(refresh.deadline).toBe(Date.parse(next))
  })

  test('an invalidated failed request does not schedule a retry', async () => {
    let reject
    fetch.mockReturnValueOnce(new Promise((_, fail) => { reject = fail }))
    const request = refresh.refresh()
    refresh.invalidate()
    reject(new Error('offline'))
    await request
    expect(apply).not.toHaveBeenCalled()
    expect(jest.getTimerCount()).toBe(0)
  })

  test('invalidation during apply prevents the old deadline from being scheduled', async () => {
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [], refresh_at: deadline(1000) }) })
    apply.mockImplementationOnce(async (_, current) => {
      expect(current()).toBe(true)
      refresh.invalidate()
      expect(current()).toBe(false)
    })
    await refresh.refresh()
    expect(apply).toHaveBeenCalledTimes(1)
    expect(jest.getTimerCount()).toBe(0)
  })

  test('a newer request supersedes an older in-flight response', async () => {
    let resolve
    fetch.mockReturnValueOnce(new Promise((done) => { resolve = done }))
    fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: ['new'], refresh_at: null }) })
    const older = refresh.refresh()
    await refresh.refresh()
    resolve({ ok: true, json: async () => ({ items: ['old'], refresh_at: deadline(1000) }) })
    await older
    expect(apply).toHaveBeenCalledTimes(1)
    expect(apply).toHaveBeenCalledWith(['new'], expect.any(Function))
    expect(jest.getTimerCount()).toBe(0)
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
