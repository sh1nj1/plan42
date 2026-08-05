/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

describe('CommentsListController docked startup', () => {
  test('ignores a repeated topic selection while a deep link is loading', () => {
    const controller = Object.create(CommentsListController.prototype)
    controller.currentTopicId = '12'
    controller.highlightAfterLoad = '34'
    controller.initialLoadComplete = false
    controller.resetToLatest = jest.fn()

    controller.handleTopicChange({ detail: { topicId: '12' } })

    expect(controller.resetToLatest).not.toHaveBeenCalled()
    expect(controller.highlightAfterLoad).toBe('34')
  })
})
