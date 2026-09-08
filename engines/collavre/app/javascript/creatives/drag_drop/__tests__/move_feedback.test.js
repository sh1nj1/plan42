/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

const alertDialog = jest.fn()
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }))

const { reportPartialMove } = await import('../move_feedback')

let consoleError

beforeEach(() => {
  consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
  consoleError.mockRestore()
  jest.clearAllMocks()
})

test('relays the rejection the server phrased for the rows that failed', () => {
  const reported = reportPartialMove({
    status: 'partial',
    failedIds: ['3'],
    failures: [{
      id: '3',
      reason: 'permission_denied',
      message: 'HTTP 403: Forbidden',
      serverMessage: '이동 권한이 없습니다.',
    }],
  })

  expect(reported).toBe(true)
  expect(alertDialog).toHaveBeenCalledWith('이동 권한이 없습니다.')
  expect(consoleError).toHaveBeenCalledWith(
    'Creative move partially failed',
    expect.objectContaining({ failedIds: ['3'] })
  )
})

// There is no client-side copy for a move rejection, so a silent server leaves
// the log as the only record rather than an untranslated placeholder dialog.
test('logs without a dialog when the server explained nothing', () => {
  const reported = reportPartialMove({
    status: 'partial',
    failedIds: ['3'],
    failures: [{ id: '3', reason: 'network_error', message: '' }],
  })

  expect(reported).toBe(true)
  expect(alertDialog).not.toHaveBeenCalled()
  expect(consoleError).toHaveBeenCalled()
})

test('uses translated page copy instead of an HTTP status fallback', () => {
  reportPartialMove({
    status: 'partial',
    failedIds: ['3'],
    failures: [{
      id: '3',
      reason: 'permission_denied',
      message: 'HTTP 403: Forbidden',
      serverMessage: '',
    }],
  }, '일부 크리에이티브를 링크하지 못했습니다. 다시 시도해 주세요.')

  expect(alertDialog).toHaveBeenCalledWith(
    '일부 크리에이티브를 링크하지 못했습니다. 다시 시도해 주세요.'
  )
})

test('stays out of the way for any other outcome', () => {
  expect(reportPartialMove({ status: 'success', failures: [] })).toBe(false)
  expect(reportPartialMove(null)).toBe(false)
  expect(reportPartialMove({ status: 'partial' })).toBe(true)

  expect(alertDialog).not.toHaveBeenCalled()
})
