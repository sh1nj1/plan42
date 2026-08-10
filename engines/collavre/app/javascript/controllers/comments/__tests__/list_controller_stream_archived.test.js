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
const buildController = ({ currentTopicId = '', archivedIds = [], withPopup = true } = {}) => {
  const controller = Object.create(CommentsListController.prototype)
  controller.manualSearchQuery = null
  controller.currentTopicId = currentTopicId
  controller.allNewerLoaded = true

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
})
