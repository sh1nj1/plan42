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
    global.fetch = jest.fn().mockResolvedValue({ ok: true })
  })

  afterEach(() => {
    document.head.innerHTML = ''
    delete global.fetch
    jest.clearAllMocks()
  })

  test('sends the client id alongside the topic', async () => {
    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBe(true)

    expect(global.fetch).toHaveBeenCalledWith(
      '/creatives/42/user_creative_preferences/update_last_topic',
      expect.objectContaining({ method: 'PATCH' }),
    )
    expect(bodyOfLastCall()).toEqual({ last_topic_id: '3', client_id: 'save-abc' })
  })

  test('sends null for both when clearing the selection anonymously', async () => {
    await saveLastTopic('42', null)

    expect(bodyOfLastCall()).toEqual({ last_topic_id: null, client_id: null })
  })

  test('reports a rejected save rather than throwing', async () => {
    global.fetch.mockResolvedValue({ ok: false })

    await expect(saveLastTopic('42', '3', 'save-abc')).resolves.toBe(false)
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
