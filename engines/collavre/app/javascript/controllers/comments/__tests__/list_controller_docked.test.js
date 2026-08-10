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

  test('loads the newly selected topic when it supersedes a pending deep link', () => {
    const controller = Object.create(CommentsListController.prototype)
    controller.currentTopicId = '12'
    controller.highlightAfterLoad = '34'
    controller.initialLoadComplete = false
    controller.resetToLatest = jest.fn()

    controller.handleTopicChange({ detail: { topicId: '13' } })

    expect(controller.currentTopicId).toBe('13')
    expect(controller.highlightAfterLoad).toBeNull()
    expect(controller.resetToLatest).toHaveBeenCalledTimes(1)
  })

  test('suppresses only the topic event emitted during popup initialization', () => {
    const controller = Object.create(CommentsListController.prototype)
    controller.currentTopicId = '12'
    controller.highlightAfterLoad = '34'
    controller.initialLoadComplete = false
    controller.suppressTopicChangeLoad = true
    controller.resetToLatest = jest.fn()

    controller.handleTopicChange({ detail: { topicId: '13' } })

    expect(controller.currentTopicId).toBe('13')
    expect(controller.highlightAfterLoad).toBe('34')
    expect(controller.resetToLatest).not.toHaveBeenCalled()
  })

  test('does not carry a pending highlight into a different creative', () => {
    const controller = Object.create(CommentsListController.prototype)
    controller.creativeId = '12'
    controller.highlightAfterLoad = '34'
    controller.highlightCreativeId = '12'
    controller.deepLinkCommentId = null
    controller.resetState = jest.fn()
    controller.loadInitialComments = jest.fn()
    controller.listTarget = { innerHTML: '' }
    Object.defineProperty(controller, 'element', { value: { dataset: { loadingText: 'Loading' } } })
    Object.defineProperty(controller, 'presenceController', { value: null })

    // Popup initialization pre-sets creativeId before this method runs, so the
    // highlight must be tied to its original creative rather than that field.
    controller.creativeId = '13'
    controller.onPopupOpened({ creativeId: '13' })

    expect(controller.highlightAfterLoad).toBeNull()
    expect(controller.loadInitialComments).toHaveBeenCalledTimes(1)
  })

  test('ignores a rejected comments request after the popup closes', async () => {
    const controller = Object.create(CommentsListController.prototype)
    let rejectRequest
    controller.creativeId = '12'
    controller.currentTopicId = ''
    controller.highlightAfterLoad = null
    controller._loadCommentsVersion = 0
    controller.selection = new Set()
    controller.prevMsgNavigator = { reset: jest.fn() }
    controller.fetchComments = jest.fn(() => new Promise((_resolve, reject) => { rejectRequest = reject }))
    controller.resetState = jest.fn()
    controller.listTarget = { innerHTML: 'Loading' }

    controller.loadInitialComments()
    controller.onPopupClosed()
    rejectRequest(new Error('stale failure'))
    await Promise.resolve()
    await Promise.resolve()

    expect(controller.listTarget.innerHTML).toBe('')
  })

  test('accepts the topic resolved by an earlier-message deep link', async () => {
    const controller = Object.create(CommentsListController.prototype)
    const element = document.createElement('section')
    const listTarget = document.createElement('div')
    element.appendChild(listTarget)
    controller.creativeId = '12'
    controller.currentTopicId = '7'
    controller.highlightAfterLoad = '34'
    controller.highlightCreativeId = '12'
    controller._loadCommentsVersion = 0
    controller.selection = new Set()
    controller.prevMsgNavigator = { reset: jest.fn() }
    controller.fetchComments = jest.fn(async () => {
      controller.currentTopicId = '9'
      return '<div id="comment_34">Earlier message</div>'
    })
    controller.highlightComment = jest.fn()
    controller.markCommentsRead = jest.fn()
    controller.listTarget = listTarget
    Object.defineProperty(controller, 'element', { value: element })
    Object.defineProperty(controller, 'popupController', { value: null })
    Object.defineProperty(controller, 'formController', { value: null })

    controller.loadInitialComments()
    await Promise.resolve()
    await Promise.resolve()

    expect(controller.fetchComments).toHaveBeenCalledWith({ around_comment_id: '34' })
    expect(controller.highlightComment).toHaveBeenCalledWith('34')
    expect(controller.initialLoadComplete).toBe(true)
  })
})
