/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { sendNewOrder, sendLinkedCreative } from '../drag_drop'
import { ApiError } from '../api_error'

function stubFetch({ status = 200, statusText = 'OK', body = '' } = {}) {
  const response = {
    ok: status >= 200 && status < 300,
    status,
    statusText,
    headers: new Headers(),
    json: async () => JSON.parse(body || '{}'),
    text: async () => body,
  }
  const fetchMock = jest.fn().mockResolvedValue(response)
  global.fetch = fetchMock
  return fetchMock
}

function bodyOf(fetchMock) {
  return JSON.parse(fetchMock.mock.calls[0][1].body)
}

afterEach(() => {
  delete global.fetch
})

describe('sendNewOrder', () => {
  test('sends a single drag as dragged_id', async () => {
    const fetchMock = stubFetch()

    await sendNewOrder({ draggedId: '3', targetId: '9', direction: 'child' })

    expect(fetchMock.mock.calls[0][0]).toBe('/creatives/reorder')
    expect(bodyOf(fetchMock)).toEqual({ dragged_id: '3', target_id: '9', direction: 'child' })
  })

  test('sends a multi-drag as dragged_ids', async () => {
    const fetchMock = stubFetch()

    await sendNewOrder({ draggedIds: ['3', '4'], targetId: '9', direction: 'down' })

    expect(bodyOf(fetchMock)).toEqual({ dragged_ids: ['3', '4'], target_id: '9', direction: 'down' })
  })

  test('resolves the raw response so the caller can branch on ok', async () => {
    stubFetch({ status: 422, statusText: 'Unprocessable Entity' })

    const response = await sendNewOrder({ draggedId: '3', targetId: '9', direction: 'up' })

    expect(response.ok).toBe(false)
    expect(response.status).toBe(422)
  })
})

describe('sendLinkedCreative', () => {
  test('resolves the created node payload', async () => {
    stubFetch({ body: JSON.stringify({ creative_id: 31, parent_id: 9 }) })

    await expect(sendLinkedCreative({ draggedId: '3', targetId: '9', direction: 'child' }))
      .resolves.toEqual({ creative_id: 31, parent_id: 9 })
  })

  // Without the status a caller cannot tell "you may not do that" from "the
  // server is down", and the multi-link partial-success report collapses into
  // one undifferentiated failure.
  test('carries the HTTP status on failure', async () => {
    stubFetch({ status: 403, statusText: 'Forbidden' })

    const error = await sendLinkedCreative({ draggedId: '3', targetId: '9', direction: 'child' })
      .catch((caught) => caught)

    expect(error).toBeInstanceOf(ApiError)
    expect(error.status).toBe(403)
  })

  test('surfaces the server error message when the body carries one', async () => {
    stubFetch({
      status: 422,
      statusText: 'Unprocessable Entity',
      body: JSON.stringify({ error: 'Invalid creatives' }),
    })

    const error = await sendLinkedCreative({ draggedId: '3', targetId: '9', direction: 'child' })
      .catch((caught) => caught)

    expect(error.message).toBe('Invalid creatives')
  })

  test('falls back to the status line when the failure body is empty', async () => {
    stubFetch({ status: 500, statusText: 'Internal Server Error' })

    const error = await sendLinkedCreative({ draggedId: '3', targetId: '9', direction: 'child' })
      .catch((caught) => caught)

    expect(error.message).toBe('HTTP 500: Internal Server Error')
  })
})
