/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  MOVE_MODES,
  MOVE_DIRECTIONS,
  MOVE_FAILURE_REASONS,
  InvalidMoveCommandError,
  createMoveCommand,
  executeMoveCommand,
} from '../move_command'

function okResponse() {
  return { ok: true, status: 200 }
}

function failedResponse(status = 422) {
  return { ok: false, status }
}

// Stands in for the ApiError thrown by sendLinkedCreative on a non-ok response.
function httpError(status, message = `HTTP ${status}`) {
  const error = new Error(message)
  error.status = status
  return error
}

describe('createMoveCommand', () => {
  test('normalises a single numeric id into a string array', () => {
    const command = createMoveCommand({ ids: 7, targetId: 9, direction: 'child' })

    expect(command.ids).toEqual(['7'])
    expect(command.targetId).toBe('9')
  })

  test('drops blank and duplicate ids while preserving first-seen order', () => {
    const command = createMoveCommand({
      ids: ['3', '', '5', ' ', '3', null, 4],
      targetId: '9',
      direction: 'up',
    })

    expect(command.ids).toEqual(['3', '5', '4'])
  })

  test('defaults the mode to a plain move', () => {
    const command = createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' })

    expect(command.mode).toBe(MOVE_MODES.MOVE)
  })

  test('returns a frozen command so adapters cannot mutate it mid-flight', () => {
    const command = createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' })

    expect(Object.isFrozen(command)).toBe(true)
    expect(Object.isFrozen(command.ids)).toBe(true)
  })

  test('rejects an empty selection', () => {
    expect(() => createMoveCommand({ ids: ['', null], targetId: '9', direction: 'up' }))
      .toThrow(expect.objectContaining({ reason: 'empty_ids' }))
  })

  test('rejects a missing target', () => {
    expect(() => createMoveCommand({ ids: ['3'], targetId: '  ', direction: 'up' }))
      .toThrow(expect.objectContaining({ reason: 'missing_target' }))
  })

  test('rejects an unknown direction', () => {
    expect(() => createMoveCommand({ ids: ['3'], targetId: '9', direction: 'sideways' }))
      .toThrow(expect.objectContaining({ reason: 'invalid_direction' }))
  })

  test('rejects an unknown mode', () => {
    expect(() => createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up', mode: 'copy' }))
      .toThrow(expect.objectContaining({ reason: 'invalid_mode' }))
  })

  test('rejects a selection that contains its own drop target', () => {
    expect(() => createMoveCommand({ ids: ['3', '9'], targetId: '9', direction: 'child' }))
      .toThrow(expect.objectContaining({ reason: 'target_in_selection' }))
  })

  test('throws InvalidMoveCommandError, not a bare Error', () => {
    expect(() => createMoveCommand({ ids: [], targetId: '9', direction: 'up' }))
      .toThrow(InvalidMoveCommandError)
  })

  test('accepts every supported direction', () => {
    MOVE_DIRECTIONS.forEach((direction) => {
      expect(createMoveCommand({ ids: ['3'], targetId: '9', direction }).direction).toBe(direction)
    })
  })
})

describe('executeMoveCommand — move mode', () => {
  test('sends a single-id selection as dragged_id, not dragged_ids', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(okResponse())

    await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child' }),
      { api: { sendNewOrder } }
    )

    expect(sendNewOrder).toHaveBeenCalledWith({ draggedId: '3', targetId: '9', direction: 'child' })
  })

  test('sends a multi-id selection as dragged_ids', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(okResponse())

    await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'down' }),
      { api: { sendNewOrder } }
    )

    expect(sendNewOrder).toHaveBeenCalledWith({
      draggedIds: ['3', '4'],
      targetId: '9',
      direction: 'down',
    })
  })

  test('reports every id as succeeded when the reorder is accepted', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(okResponse())

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'down' }),
      { api: { sendNewOrder } }
    )

    expect(result.status).toBe('success')
    expect(result.ok).toBe(true)
    expect(result.succeededIds).toEqual(['3', '4'])
    expect(result.failedIds).toEqual([])
    expect(result.failures).toEqual([])
  })

  test('a rejected reorder fails the whole selection — the server batch is atomic', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(failedResponse(422))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'down' }),
      { api: { sendNewOrder } }
    )

    expect(result.status).toBe('failure')
    expect(result.ok).toBe(false)
    expect(result.succeededIds).toEqual([])
    expect(result.failedIds).toEqual(['3', '4'])
    expect(result.failures.map((failure) => failure.reason))
      .toEqual([MOVE_FAILURE_REASONS.REJECTED, MOVE_FAILURE_REASONS.REJECTED])
  })

  test('a 403 is reported as a permission failure, not a generic rejection', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(failedResponse(403))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' }),
      { api: { sendNewOrder } }
    )

    expect(result.failures[0]).toMatchObject({
      id: '3',
      status: 403,
      reason: MOVE_FAILURE_REASONS.PERMISSION_DENIED,
    })
  })

  test('a 500 is reported as a server failure', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(failedResponse(500))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' }),
      { api: { sendNewOrder } }
    )

    expect(result.failures[0].reason).toBe(MOVE_FAILURE_REASONS.SERVER_ERROR)
  })

  test('a transport error resolves to a failure result instead of rejecting', async () => {
    const sendNewOrder = jest.fn().mockRejectedValue(new Error('offline'))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' }),
      { api: { sendNewOrder } }
    )

    expect(result.status).toBe('failure')
    expect(result.failures[0]).toMatchObject({
      id: '3',
      reason: MOVE_FAILURE_REASONS.NETWORK_ERROR,
      message: 'offline',
    })
  })
})

describe('executeMoveCommand — link mode', () => {
  test('issues one link_drop per selected id', async () => {
    const sendLinkedCreative = jest.fn().mockResolvedValue({ creative_id: 1 })

    await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'child', mode: MOVE_MODES.LINK }),
      { api: { sendLinkedCreative } }
    )

    expect(sendLinkedCreative).toHaveBeenCalledTimes(2)
    expect(sendLinkedCreative).toHaveBeenNthCalledWith(1, { draggedId: '3', targetId: '9', direction: 'child' })
    expect(sendLinkedCreative).toHaveBeenNthCalledWith(2, { draggedId: '4', targetId: '9', direction: 'child' })
  })

  test('returns the server payloads in selection order', async () => {
    const sendLinkedCreative = jest.fn(({ draggedId }) =>
      Promise.resolve({ creative_id: Number(draggedId) * 10 }))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.status).toBe('success')
    expect(result.payloads).toEqual([
      { id: '3', data: { creative_id: 30 } },
      { id: '4', data: { creative_id: 40 } },
    ])
  })

  test('one failing link still attempts the rest and reports a partial success', async () => {
    const sendLinkedCreative = jest.fn(({ draggedId }) =>
      draggedId === '4' ? Promise.reject(httpError(422)) : Promise.resolve({ creative_id: 1 }))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4', '5'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(sendLinkedCreative).toHaveBeenCalledTimes(3)
    expect(result.status).toBe('partial')
    expect(result.ok).toBe(false)
    expect(result.succeededIds).toEqual(['3', '5'])
    expect(result.failedIds).toEqual(['4'])
  })

  test('a partial link result keeps the shells that were already created', async () => {
    const sendLinkedCreative = jest.fn(({ draggedId }) =>
      draggedId === '4' ? Promise.reject(httpError(422)) : Promise.resolve({ creative_id: 1 }))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.payloads).toEqual([{ id: '3', data: { creative_id: 1 } }])
    expect(result.rolledBack).toBe(false)
  })

  test('every link failing reports a plain failure, not a partial success', async () => {
    const sendLinkedCreative = jest.fn().mockRejectedValue(httpError(422))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.status).toBe('failure')
    expect(result.succeededIds).toEqual([])
  })

  test('classifies a 403 link failure as a permission failure', async () => {
    const sendLinkedCreative = jest.fn().mockRejectedValue(httpError(403))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.failures[0].reason).toBe(MOVE_FAILURE_REASONS.PERMISSION_DENIED)
  })

  test('classifies a status-less link failure as a transport failure', async () => {
    const sendLinkedCreative = jest.fn().mockRejectedValue(new Error('offline'))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.failures[0].reason).toBe(MOVE_FAILURE_REASONS.NETWORK_ERROR)
  })

  test('runs the link requests one at a time so the server resequence cannot race', async () => {
    let inFlight = 0
    let maxInFlight = 0
    const sendLinkedCreative = jest.fn(() => {
      inFlight += 1
      maxInFlight = Math.max(maxInFlight, inFlight)
      return new Promise((resolve) => {
        setTimeout(() => {
          inFlight -= 1
          resolve({ creative_id: 1 })
        }, 0)
      })
    })

    await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4', '5'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(maxInFlight).toBe(1)
  })

  test('links downwards in reverse so the shells land in selection order', async () => {
    const seen = []
    const sendLinkedCreative = jest.fn(({ draggedId }) => {
      seen.push(draggedId)
      return Promise.resolve({ creative_id: 1 })
    })

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4', '5'], targetId: '9', direction: 'down', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    // Each "down" link inserts directly after the target, so the last request
    // ends up closest to it. Sending the selection backwards is what makes the
    // final sibling order read 3, 4, 5.
    expect(seen).toEqual(['5', '4', '3'])
    expect(result.succeededIds).toEqual(['3', '4', '5'])
  })

  test('links upwards in selection order', async () => {
    const seen = []
    const sendLinkedCreative = jest.fn(({ draggedId }) => {
      seen.push(draggedId)
      return Promise.resolve({ creative_id: 1 })
    })

    await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'up', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(seen).toEqual(['3', '4'])
  })
})

describe('executeMoveCommand — contract', () => {
  test('normalises a plain object command', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(okResponse())

    const result = await executeMoveCommand(
      { ids: [3], targetId: 9, direction: 'up' },
      { api: { sendNewOrder } }
    )

    expect(result.command.ids).toEqual(['3'])
    expect(result.succeededIds).toEqual(['3'])
  })

  test('an invalid command is the only rejection path', async () => {
    await expect(executeMoveCommand({ ids: [], targetId: '9', direction: 'up' }, { api: {} }))
      .rejects.toThrow(InvalidMoveCommandError)
  })
})

describe('executeMoveCommand — defensive paths', () => {
  test('createMoveCommand called with no intent at all rejects as an empty selection', () => {
    expect(() => createMoveCommand()).toThrow(expect.objectContaining({ reason: 'empty_ids' }))
  })

  test('a reorder that resolves nothing at all is a transport failure, not a success', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(undefined)

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' }),
      { api: { sendNewOrder } }
    )

    expect(result.status).toBe('failure')
    expect(result.failures[0].reason).toBe(MOVE_FAILURE_REASONS.NETWORK_ERROR)
  })

  test('a rejection carrying no error object is still reported per id', async () => {
    const sendLinkedCreative = jest.fn().mockRejectedValue(undefined)

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.failures[0]).toMatchObject({
      id: '3',
      status: null,
      reason: MOVE_FAILURE_REASONS.NETWORK_ERROR,
      message: '',
    })
  })

  test('falls back to the real reorder endpoint when no api override is given', async () => {
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      status: 200,
      headers: new Headers(),
    })
    global.fetch = fetchMock

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' })
    )

    expect(fetchMock.mock.calls[0][0]).toBe('/creatives/reorder')
    expect(result.status).toBe('success')
    delete global.fetch
  })
})

// An expired session sends *any* request to the login page
// (Authentication#request_authentication redirects unconditionally), and fetch
// follows that redirect and hands back a perfectly ok HTML response. Trusting
// `response.ok` alone would report a move that never reached the endpoint as
// applied, and the adapter would keep an optimistic DOM the database disagrees
// with until the next reload.
describe('executeMoveCommand — expired session', () => {
  test('a reorder answered by the login redirect is not a success', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue({ ok: true, status: 200, redirected: true })

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3', '4'], targetId: '9', direction: 'child' }),
      { api: { sendNewOrder } }
    )

    expect(result.status).toBe('failure')
    expect(result.succeededIds).toEqual([])
    expect(result.failures.map((failure) => failure.reason))
      .toEqual([
        MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED,
        MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED,
      ])
  })

  test('a 401 asks for a new session rather than blaming permissions', async () => {
    const sendNewOrder = jest.fn().mockResolvedValue(failedResponse(401))

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'up' }),
      { api: { sendNewOrder } }
    )

    expect(result.failures[0].reason).toBe(MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED)
  })

  test('a link rejected as unauthenticated is reported as such', async () => {
    const error = new Error('Authentication required')
    error.status = 200
    error.authenticationRequired = true
    const sendLinkedCreative = jest.fn().mockRejectedValue(error)

    const result = await executeMoveCommand(
      createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child', mode: 'link' }),
      { api: { sendLinkedCreative } }
    )

    expect(result.failures[0].reason).toBe(MOVE_FAILURE_REASONS.AUTHENTICATION_REQUIRED)
  })
})
