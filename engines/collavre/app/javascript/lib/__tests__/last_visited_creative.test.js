/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { nextLastVisitedCreativeSequence } from '../last_visited_creative'

describe('nextLastVisitedCreativeSequence', () => {
  test('remains monotonic when localStorage is unavailable', () => {
    const localStorageGetter = jest.spyOn(window, 'localStorage', 'get').mockImplementation(() => {
      throw new DOMException('Access denied', 'SecurityError')
    })

    const firstSequence = nextLastVisitedCreativeSequence('token', 1)

    expect(nextLastVisitedCreativeSequence('token', 1)).toBe(firstSequence + 1)

    localStorageGetter.mockRestore()
  })
})
