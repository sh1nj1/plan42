/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

// Builds the shape handleStreamRender reads off a turbo:before-stream-render
// event: the <turbo-stream> element plus a preventDefault spy.
const streamEvent = ({ action = 'append', target = 'comments-list', html = '' } = {}) => {
  const template = document.createElement('template')
  template.innerHTML = html
  return {
    preventDefault: jest.fn(),
    target: { action, target, templateContent: template.content },
  }
}

const buildController = ({ manualSearchQuery = null, currentTopicId = null } = {}) => {
  const controller = Object.create(CommentsListController.prototype)
  controller.manualSearchQuery = manualSearchQuery
  controller.currentTopicId = currentTopicId
  controller.allNewerLoaded = true
  return controller
}

describe('CommentsListController live appends during search', () => {
  test('blocks a live comment while a search is active', () => {
    const controller = buildController({ manualSearchQuery: 'invoice' })
    const event = streamEvent({
      html: '<div id="comment_9" class="comment-item" data-topic-id="">unrelated chatter</div>',
    })

    controller.handleStreamRender(event)

    // The server decides what matches; an append carries no such verdict, so it
    // must not land in the result set (nor clear #no-search-results with it).
    expect(event.preventDefault).toHaveBeenCalledTimes(1)
  })

  test('blocks it even when the message would match the query', () => {
    // Deliberate: matching client-side would have to reimplement the
    // controller's multi-word LOWER(content) LIKE filter over raw markdown.
    // The snapshot stays consistent instead of half-refreshed.
    const controller = buildController({ manualSearchQuery: 'invoice' })
    const event = streamEvent({
      html: '<div id="comment_9" class="comment-item" data-topic-id="">the invoice is ready</div>',
    })

    controller.handleStreamRender(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
  })

  test('lets live comments through when no search is active', () => {
    const controller = buildController({ manualSearchQuery: null })
    const event = streamEvent({
      html: '<div id="comment_9" class="comment-item" data-topic-id="">hello</div>',
    })

    controller.handleStreamRender(event)

    expect(event.preventDefault).not.toHaveBeenCalled()
  })

  test('still applies edits and deletions to comments inside the results', () => {
    // Only appends are filtered. A replace/remove targets a comment already in
    // the result set, so suppressing it would leave stale text on screen.
    const controller = buildController({ manualSearchQuery: 'invoice' })

    const replace = streamEvent({ action: 'replace' })
    const remove = streamEvent({ action: 'remove' })
    controller.handleStreamRender(replace)
    controller.handleStreamRender(remove)

    expect(replace.preventDefault).not.toHaveBeenCalled()
    expect(remove.preventDefault).not.toHaveBeenCalled()
  })

  test('ignores streams aimed at another target', () => {
    const controller = buildController({ manualSearchQuery: 'invoice' })
    const event = streamEvent({ target: 'topic-list' })

    controller.handleStreamRender(event)

    expect(event.preventDefault).not.toHaveBeenCalled()
  })

  test('resetState clears the filter so live comments resume', () => {
    const controller = buildController({ manualSearchQuery: 'invoice' })
    controller.selection = new Set()
    controller.notifySelectionChange = jest.fn()

    controller.resetState()

    const event = streamEvent({
      html: '<div id="comment_9" class="comment-item" data-topic-id="">hello</div>',
    })
    controller.handleStreamRender(event)

    expect(controller.manualSearchQuery).toBeNull()
    expect(event.preventDefault).not.toHaveBeenCalled()
  })
})
