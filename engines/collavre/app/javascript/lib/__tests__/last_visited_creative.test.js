/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { nextLastVisitedCreativeSequence } from '../last_visited_creative'

describe('nextLastVisitedCreativeSequence', () => {
  test('defers sequence allocation to Rails when localStorage is unavailable', () => {
    const localStorageGetter = jest.spyOn(window, 'localStorage', 'get').mockImplementation(() => {
      throw new DOMException('Access denied', 'SecurityError')
    })

    expect(nextLastVisitedCreativeSequence(1)).toBeNull()
    expect(nextLastVisitedCreativeSequence(1)).toBeNull()

    localStorageGetter.mockRestore()
  })
})
