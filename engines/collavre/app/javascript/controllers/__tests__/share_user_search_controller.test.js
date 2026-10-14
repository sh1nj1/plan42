import { jest } from '@jest/globals'
import ShareUserSearchController from '../share_user_search_controller'

describe('share user search keyboard delegation', () => {
  test.each(['ArrowDown', 'ArrowUp', 'Enter'])('delegates %s to popup', key => {
    const controller = Object.create(ShareUserSearchController.prototype)
    controller.popup = { handleKey: jest.fn().mockReturnValue(true) }
    const event = { key }
    controller.handleKey(event)
    expect(controller.popup.handleKey).toHaveBeenCalledWith(event)
  })

  test('handles absent popup', () => {
    const controller = Object.create(ShareUserSearchController.prototype)
    expect(() => controller.handleKey({ key: 'Enter' })).not.toThrow()
  })
})
