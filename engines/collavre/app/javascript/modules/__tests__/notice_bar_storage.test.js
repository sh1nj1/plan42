import { jest } from '@jest/globals'
import { parseJSON, readSession, writeSession } from '../notice_bar/storage'

describe('notice bar storage helpers', () => {
  afterEach(() => {
    jest.restoreAllMocks()
    sessionStorage.clear()
  })

  test('parseJSON falls back on empty or malformed input', () => {
    expect(parseJSON('{"a":1}', null)).toEqual({ a: 1 })
    expect(parseJSON('', [])).toEqual([])
    expect(parseJSON('{oops', 'fallback')).toBe('fallback')
  })

  test('session reads and writes round-trip', () => {
    writeSession('k', 'v')
    expect(readSession('k')).toBe('v')
  })

  test('session access survives disabled storage', () => {
    jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('denied') })
    jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('denied') })
    expect(readSession('k')).toBeNull()
    expect(() => writeSession('k', 'v')).not.toThrow()
  })
})
