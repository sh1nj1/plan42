/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

describe('comment loading placeholders', () => {
  test.each(['onPopupOpened', 'resetToLatest', 'applySearchQuery'])('%s displays the emoji loading indicator while loading', (method) => {
    const controller = Object.create(CommentsListController.prototype)
    Object.defineProperties(controller, {
      element: { value: document.createElement('div') },
      listTarget: { value: document.createElement('div') },
      presenceController: { value: null },
    })
    controller.flushPendingRead = jest.fn()
    controller.resetState = jest.fn()
    controller.getCommentReadTracker = () => ({ resetRenderedSnapshot: jest.fn() })
    controller.loadInitialComments = jest.fn()

    controller[method]()

    expect(controller.listTarget.querySelector('[role="status"]')).not.toBeNull()
    expect(controller.listTarget.querySelectorAll('.creative-loading-dot')).toHaveLength(3)
    expect(controller.listTarget.textContent).not.toContain('Loading')
    expect(controller.loadInitialComments).toHaveBeenCalledTimes(1)
  })

  test('search uses the localized server placeholder when supplied', () => {
    const controller = Object.create(CommentsListController.prototype)
    const element = document.createElement('div')
    element.dataset.loadingHtml = '<div role="status" aria-label="불러오는 중"><div class="comments-loading-row"></div></div>'
    Object.defineProperties(controller, {
      element: { value: element },
      listTarget: { value: document.createElement('div') },
    })
    controller.flushPendingRead = jest.fn()
    controller.resetState = jest.fn()
    controller.loadInitialComments = jest.fn()

    controller.applySearchQuery('hello')

    expect(controller.listTarget.querySelector('[role="status"]').getAttribute('aria-label')).toBe('불러오는 중')
    expect(controller.manualSearchQuery).toBe('hello')
  })
})
