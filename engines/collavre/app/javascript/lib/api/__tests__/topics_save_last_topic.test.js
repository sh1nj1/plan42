/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { saveLastTopic } from '../topics'

// update_last_topic broadcasts to every session of the saving user, and the
// broadcast echoes back whatever client_id the save carried. That id is the
// only thing that tells the session which made the save apart from a sibling
// session that happened to pick the same topic, so it has to reach the server.
describe('saveLastTopic', () => {
  const bodyOfLastCall = () => JSON.parse(global.fetch.mock.calls.at(-1)[1].body)

  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="test-csrf">'
    global.fetch = jest.fn().mockImplementation((url, options) => {
      if (options?.method === 'POST') {
        return Promise.resolve({ ok: true, json: async () => ({ last_topic_save_fence: 1 }) })
      }
      return Promise.resolve({ ok: true, json: async () => ({}) })
    })
  })

  afterEach(() => {
    document.head.innerHTML = ''
    delete global.fetch
    jest.clearAllMocks()
  })

  test('sends the client id alongside the topic', async () => {
    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toEqual({ success: true, lastTopicRevision: undefined })

    expect(global.fetch).toHaveBeenCalledWith(
      '/creatives/42/user_creative_preferences/update_last_topic',
      expect.objectContaining({ method: 'PATCH' }),
    )
    expect(bodyOfLastCall()).toEqual({ last_topic_id: '3', client_id: 'save-abc', last_topic_save_fence: 1 })
  })

  test('forwards an abort signal to the request', async () => {
    const abortController = new AbortController()

    await saveLastTopic('42', '3', 'save-abc', abortController.signal)

    expect(global.fetch).toHaveBeenCalledWith(
      '/creatives/42/user_creative_preferences/update_last_topic',
      expect.objectContaining({ signal: abortController.signal }),
    )
  })

  test('sends null for both when clearing the selection anonymously', async () => {
    await saveLastTopic('42', null)

    expect(bodyOfLastCall()).toEqual({ last_topic_id: null, client_id: null, last_topic_save_fence: 1 })
  })

  test('reports a rejected save rather than throwing', async () => {
    global.fetch.mockResolvedValue({ ok: false })

    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBe(false)
  })

  test('reports a stale ordered save as definitively rejected', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ last_topic_save_fence: 1 }) })
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ success: false }) })

    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBe(false)
  })

  test('does not PATCH when issuing the save fence is ambiguous', async () => {
    global.fetch.mockResolvedValue({ ok: false, status: 502 })

    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBeNull()
    expect(global.fetch).toHaveBeenCalledTimes(1)
  })

  test('reports an ambiguous network failure separately from an HTTP rejection', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch.mockRejectedValue(new Error('offline'))

    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBeNull()
  })

  test.each([ 502, 504 ])('treats gateway status %i as an ambiguous delivery', async (status) => {
    global.fetch.mockResolvedValue({ ok: false, status })

    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBeNull()
  })
})
