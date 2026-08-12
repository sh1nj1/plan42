/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

const streamEvent = ({ action = 'append', target = 'comments-list', html = '' } = {}) => {
  const template = document.createElement('template')
  template.innerHTML = html
  return {
    preventDefault: jest.fn(),
    target: { action, target, templateContent: template.content },
  }
}

const comment = (topicId) =>
  `<div id="comment_9" class="comment-item" data-topic-id="${topicId}">hello</div>`

// currentTopicId "" is the All Messages view. archivedIds stands in for the
// topics controller's archived_topics, which is what the real lookup reads.
const buildController = ({ currentTopicId = '', archivedIds = [], withPopup = true, searchQuery = null } = {}) => {
  const controller = Object.create(CommentsListController.prototype)
  controller.manualSearchQuery = searchQuery
  controller.currentTopicId = currentTopicId
  controller.allNewerLoaded = true
  controller.markCommentsRead = jest.fn()

  // popupController is a prototype getter reaching into this.application; an
  // own property shadows it without standing up a Stimulus application.
  Object.defineProperty(controller, 'popupController', {
    value: withPopup
      ? {
          topicsController: {
            isArchivedTopic: (id) => archivedIds.some((a) => String(a) === String(id)),
          },
        }
      : null,
  })

  return controller
}

describe('CommentsListController archived streams in All Messages', () => {
  let badgeEvents
  const onBadge = (e) => badgeEvents.push(e.detail)

  beforeEach(() => {
    badgeEvents = []
    window.addEventListener('comments--topics:new-message', onBadge)
  })

  afterEach(() => {
    window.removeEventListener('comments--topics:new-message', onBadge)
  })

  // CommentsController#index excludes archived-topic comments from All Messages,
  // so appending one live would show a message that disappears on reload.
  test('blocks an archived-topic message and badges the topic instead', () => {
    const controller = buildController({ archivedIds: [7] })
    const event = streamEvent({ html: comment(7) })

    controller.handleStreamRender(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(badgeEvents).toEqual([{ topicId: '7' }])
  })

  test('lets a live topic message through', () => {
    const controller = buildController({ archivedIds: [7] })
    const event = streamEvent({ html: comment(2) })

    controller.handleStreamRender(event)

    expect(event.preventDefault).not.toHaveBeenCalled()
    expect(badgeEvents).toEqual([])
    expect(controller.markCommentsRead).toHaveBeenCalledTimes(1)
  })

  test('does not mark a foreign message read', () => {
    const controller = buildController({ currentTopicId: '2' })
    const event = streamEvent({ html: comment(5) })

    controller.handleStreamRender(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(controller.markCommentsRead).not.toHaveBeenCalled()
  })

  test('lets a topic-less comment through without consulting the topics controller', () => {
    const controller = buildController({ archivedIds: [7], withPopup: false })
    const event = streamEvent({ html: comment('') })

    controller.handleStreamRender(event)

    expect(event.preventDefault).not.toHaveBeenCalled()
    expect(badgeEvents).toEqual([])
  })

  // The archived section may not have loaded yet on a docked chat; a missing
  // topics controller must not break live appends.
  test('appends normally when the topics controller is unavailable', () => {
    const controller = buildController({ archivedIds: [7], withPopup: false })
    const event = streamEvent({ html: comment(7) })

    controller.handleStreamRender(event)

    expect(event.preventDefault).not.toHaveBeenCalled()
  })

  test('still blocks a foreign topic when viewing a specific topic', () => {
    const controller = buildController({ currentTopicId: '2', archivedIds: [] })
    const event = streamEvent({ html: comment(5) })

    controller.handleStreamRender(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(badgeEvents).toEqual([{ topicId: '5' }])
  })

  test('appends a message for the archived topic the user is actually viewing', () => {
    const controller = buildController({ currentTopicId: '7', archivedIds: [7] })
    const event = streamEvent({ html: comment(7) })

    controller.handleStreamRender(event)

    expect(event.preventDefault).not.toHaveBeenCalled()
    expect(badgeEvents).toEqual([])
  })

  // An active search blocks every append, so the badge is the only thing left
  // that can report traffic in a topic the user cannot see. It has to survive
  // the search block, not be swallowed by it.
  describe('while a search filter is active', () => {
    test('badges an archived topic even though the append is blocked', () => {
      const controller = buildController({ archivedIds: [7], searchQuery: 'deploy' })
      const event = streamEvent({ html: comment(7) })

      controller.handleStreamRender(event)

      expect(event.preventDefault).toHaveBeenCalledTimes(1)
      expect(badgeEvents).toEqual([{ topicId: '7' }])
    })

    test('badges a foreign topic while searching inside a specific topic', () => {
      const controller = buildController({ currentTopicId: '2', searchQuery: 'deploy' })
      const event = streamEvent({ html: comment(5) })

      controller.handleStreamRender(event)

      expect(event.preventDefault).toHaveBeenCalledTimes(1)
      expect(badgeEvents).toEqual([{ topicId: '5' }])
    })

    // The search block still owns everything the topic routing lets past: the
    // result set is a server-side match and a live append carries no verdict.
    test('still blocks a message for the topic in view, without badging it', () => {
      const controller = buildController({ currentTopicId: '2', searchQuery: 'deploy' })
      const event = streamEvent({ html: comment(2) })

      controller.handleStreamRender(event)

      expect(event.preventDefault).toHaveBeenCalledTimes(1)
      expect(badgeEvents).toEqual([])
    })

    test('still blocks a live-topic message in All Messages, without badging it', () => {
      const controller = buildController({ archivedIds: [7], searchQuery: 'deploy' })
      const event = streamEvent({ html: comment(2) })

      controller.handleStreamRender(event)

      expect(event.preventDefault).toHaveBeenCalledTimes(1)
      expect(badgeEvents).toEqual([])
    })
  })
})
