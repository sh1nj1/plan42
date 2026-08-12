/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

// selectTopic persists the selection through the topics API; stub it so the
// tests stay offline and the debounce timer has nothing to flush.
jest.unstable_mockModule('../../../lib/api/topics', () => ({
  fetchNextTopicName: jest.fn(),
  createTopicWithComments: jest.fn(),
  saveLastTopic: jest.fn().mockResolvedValue(undefined),
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default
const CommentsListController = (await import('../list_controller')).default

const TOPICS = [{ id: 1, name: 'Main' }, { id: 2, name: 'Alpha' }]
const ARCHIVED = [{ id: 3, name: 'Zeta' }]

// CommentsController#index answers a deep link (around_comment_id) with the
// topic the target comment actually lives in.
const commentsResponse = (topicId) => ({
  ok: true,
  headers: { get: (name) => (name === 'X-Topic-Id' ? topicId : null) },
  text: async () => '',
})

const buildListController = ({ currentTopicId = '', topicsController = null, element = null } = {}) => {
  const controller = Object.create(CommentsListController.prototype)
  controller.creativeId = '42'
  controller.currentTopicId = currentTopicId
  controller.manualSearchQuery = null

  const list = document.createElement('div')
  Object.defineProperty(controller, 'listTarget', { value: list })
  Object.defineProperty(controller, 'element', { value: element || document.createElement('div') })
  Object.defineProperty(controller, 'popupController', {
    value: topicsController ? { topicsController, updatePosition: () => {} } : null,
  })
  // Both are prototype getters that reach into a Stimulus application; own
  // properties shadow them without standing one up.
  Object.defineProperty(controller, 'formController', { value: null })

  return controller
}

describe('CommentsListController deep-linked topic resolution', () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="test-csrf">'
  })

  afterEach(() => {
    document.head.innerHTML = ''
    jest.clearAllMocks()
  })

  // updateSelectionUI only repaints chips: it neither expands the archived
  // section nor tells form_controller which conversation the reply belongs to.
  test('routes the server-resolved topic through selectTopic', async () => {
    const topicsController = {
      setOverrideTopicId: jest.fn(),
      selectTopic: jest.fn(),
      updateSelectionUI: jest.fn(),
    }
    const controller = buildListController({ currentTopicId: '2', topicsController })
    global.fetch = jest.fn().mockResolvedValue(commentsResponse('3'))

    await controller.fetchComments({ around_comment_id: 55 })

    expect(topicsController.setOverrideTopicId).toHaveBeenCalledWith('3')
    expect(topicsController.selectTopic).toHaveBeenCalledWith('3')
    expect(controller.currentTopicId).toBe('3')
    expect(controller.listTarget.dataset.currentTopicId).toBe('3')
  })

  // loadInitialComments drops responses whose topic no longer matches the one it
  // requested, to survive creative switches. A server-resolved deep link trips
  // that guard with its own answer and the list never leaves "Loading...".
  test('renders a response that switched topic instead of discarding it as stale', async () => {
    const topicsController = { setOverrideTopicId: jest.fn(), selectTopic: jest.fn() }
    const controller = buildListController({ currentTopicId: '2', topicsController })
    controller.selection = new Set()
    controller._loadCommentsVersion = 0
    controller.prevMsgNavigator = { reset: jest.fn() }
    controller.highlightAfterLoad = 55
    controller.highlightComment = jest.fn()
    controller.markCommentsRead = jest.fn()
    controller.scrollToBottom = jest.fn()
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      headers: { get: (name) => (name === 'X-Topic-Id' ? '3' : null) },
      text: async () => '<div id="comment_55" class="comment-item">deep linked</div>',
    })

    controller.loadInitialComments()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(controller.listTarget.innerHTML).toContain('comment_55')
    expect(controller.highlightComment).toHaveBeenCalledWith(55)
  })

  // The allowance is scoped to the one request the server answered: a newer load
  // must still be able to discard this one.
  test('still discards a response superseded by a newer load', async () => {
    const topicsController = { setOverrideTopicId: jest.fn(), selectTopic: jest.fn() }
    const controller = buildListController({ currentTopicId: '2', topicsController })
    controller.selection = new Set()
    controller._loadCommentsVersion = 0
    controller.prevMsgNavigator = { reset: jest.fn() }
    controller.highlightComment = jest.fn()
    controller.markCommentsRead = jest.fn()
    controller.scrollToBottom = jest.fn()
    global.fetch = jest.fn().mockImplementation(async () => {
      controller._loadCommentsVersion += 1 // a newer load starts mid-flight
      return {
        ok: true,
        headers: { get: (name) => (name === 'X-Topic-Id' ? '3' : null) },
        text: async () => '<div id="comment_55">stale</div>',
      }
    })

    controller.loadInitialComments()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(controller.listTarget.innerHTML).not.toContain('comment_55')
  })

  test('leaves the topics controller alone when the server confirms the current topic', async () => {
    const topicsController = {
      setOverrideTopicId: jest.fn(),
      selectTopic: jest.fn(),
      updateSelectionUI: jest.fn(),
    }
    const controller = buildListController({ currentTopicId: '3', topicsController })
    global.fetch = jest.fn().mockResolvedValue(commentsResponse('3'))

    await controller.fetchComments({ around_comment_id: 55 })

    expect(topicsController.selectTopic).not.toHaveBeenCalled()
    expect(controller.listTarget.dataset.currentTopicId).toBe('3')
  })

  // A deep link that loses the race still gets its X-Topic-Id answered. Acting on
  // it would move the selection to a topic nobody is looking at any more, and the
  // load that replaced it would render into that wrong selection.
  const raceDeepLinkAgainstSelection = () => {
    const topicsController = { setOverrideTopicId: jest.fn(), selectTopic: jest.fn() }
    const controller = buildListController({ currentTopicId: '2', topicsController })
    controller.selection = new Set()
    controller._loadCommentsVersion = 0
    controller.prevMsgNavigator = { reset: jest.fn() }
    controller.highlightComment = jest.fn()
    controller.markCommentsRead = jest.fn()
    controller.scrollToBottom = jest.fn()

    let releaseDeepLink
    let releaseSelected
    const deepLinkGate = new Promise((resolve) => { releaseDeepLink = resolve })
    const selectedGate = new Promise((resolve) => { releaseSelected = resolve })

    global.fetch = jest.fn()
      .mockImplementationOnce(async () => {
        await deepLinkGate
        return {
          ok: true,
          headers: { get: (name) => (name === 'X-Topic-Id' ? '3' : null) },
          text: async () => '<div id="comment_55" class="comment-item">deep linked</div>',
        }
      })
      .mockImplementationOnce(async () => {
        await selectedGate
        return {
          ok: true,
          headers: { get: () => null },
          text: async () => '<div id="comment_99" class="comment-item">topic nine</div>',
        }
      })

    controller.highlightAfterLoad = 55
    controller.loadInitialComments()

    // The user picks another topic before the deep link comes back.
    controller.highlightAfterLoad = null
    controller.currentTopicId = '9'
    controller.loadInitialComments()

    const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
    return { controller, topicsController, releaseDeepLink, releaseSelected, flush }
  }

  test('ignores the X-Topic-Id of a load that was already superseded', async () => {
    const { controller, topicsController, releaseDeepLink, flush } = raceDeepLinkAgainstSelection()

    releaseDeepLink()
    await flush()

    expect(controller.currentTopicId).toBe('9')
    expect(topicsController.selectTopic).not.toHaveBeenCalled()
    expect(topicsController.setOverrideTopicId).not.toHaveBeenCalled()
  })

  test('does not retain the All Messages snapshot from a superseded load', async () => {
    const controller = buildListController()
    controller._loadCommentsVersion = 2
    controller.renderedAllTopicIds = ['9']
    controller.renderedAllTopicWatermarks = { 9: 90 }
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      headers: {
        get: (name) => ({
          'X-Rendered-Topic-Ids': '1,2',
          'X-Rendered-Topic-Watermarks': '{"1":10,"2":20}',
        })[name] || null,
      },
      text: async () => '',
    })

    await controller.fetchComments({}, { loadVersion: 1 })

    expect(controller.renderedAllTopicIds).toEqual(['9'])
    expect(controller.renderedAllTopicWatermarks).toEqual({ 9: 90 })
  })

  test('records whether the All Messages snapshot rendered the legacy lane', async () => {
    const controller = buildListController()
    controller._loadCommentsVersion = 1
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      headers: {
        get: (name) => ({
          'X-Rendered-Topic-Ids': '1',
          'X-Rendered-Topic-Watermarks': '{"_legacy":10,"1":20}',
        })[name] || null,
      },
      text: async () => '',
    })

    await controller.fetchComments({}, { loadVersion: 1 })

    expect(controller.renderedAllIncludesLegacy).toBe(true)
  })

  test('does not pass the topic-guard exemption to the load that superseded it', async () => {
    const { controller, releaseDeepLink, releaseSelected, flush } = raceDeepLinkAgainstSelection()

    releaseDeepLink()
    await flush()
    releaseSelected()
    await flush()

    expect(controller.isServerResolvedTopic(2)).toBe(false)
    // The surviving load rendered its own topic, and the selection it renders
    // under is the one the user picked.
    expect(controller.listTarget.innerHTML).toContain('comment_99')
    expect(controller.listTarget.dataset.currentTopicId).toBe('9')
  })

  // The exemption is only for a load the server retopiced. A load the server
  // said nothing about is still subject to the plain stale-topic guard, on both
  // the success and the failure path.
  describe('a load the server did not retopic', () => {
    const buildPendingLoad = () => {
      const topicsController = { setOverrideTopicId: jest.fn(), selectTopic: jest.fn() }
      const controller = buildListController({ currentTopicId: '2', topicsController })
      controller.selection = new Set()
      controller._loadCommentsVersion = 0
      controller.prevMsgNavigator = { reset: jest.fn() }
      controller.highlightComment = jest.fn()
      controller.markCommentsRead = jest.fn()
      controller.scrollToBottom = jest.fn()
      return controller
    }

    const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

    test('discards its HTML when the topic moved while it was in flight', async () => {
      const controller = buildPendingLoad()
      global.fetch = jest.fn().mockImplementation(async () => {
        controller.currentTopicId = '9' // the user switched mid-flight
        return {
          ok: true,
          headers: { get: () => null },
          text: async () => '<div id="comment_55">topic two</div>',
        }
      })

      controller.loadInitialComments()
      await flush()

      expect(controller.listTarget.innerHTML).not.toContain('comment_55')
    })

    test('discards its error when the topic moved while it was in flight', async () => {
      const controller = buildPendingLoad()
      global.fetch = jest.fn().mockImplementation(async () => {
        controller.currentTopicId = '9'
        return {
          ok: false,
          headers: { get: () => null },
          json: async () => ({ error: 'No permission' }),
        }
      })

      controller.loadInitialComments()
      await flush()

      expect(controller.listTarget.innerHTML).toBe('')
    })

    test('still renders its error when the topic did not move', async () => {
      const controller = buildPendingLoad()
      global.fetch = jest.fn().mockResolvedValue({
        ok: false,
        headers: { get: () => null },
        json: async () => ({ error: 'No permission' }),
      })

      controller.loadInitialComments()
      await flush()

      expect(controller.listTarget.innerHTML).toContain('No permission')
    })
  })
})

describe('CommentsListController deep link into an archived topic', () => {
  let application
  let topicsController
  let changeEvents

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="chat-popup">
        <div id="topics" data-controller="comments--topics" data-topic-main-text="All Messages">
          <div data-comments--topics-target="list"></div>
        </div>
      </div>
    `
    // jsdom has no layout, so scrollIntoView is undefined on elements.
    Element.prototype.scrollIntoView = jest.fn()
    document.head.innerHTML = '<meta name="csrf-token" content="test-csrf">'

    application = Application.start()
    application.register('comments--topics', TopicsController)

    changeEvents = []
    document.addEventListener('comments--topics:change', (e) => changeEvents.push(e.detail))

    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
      topicsController = application.getControllerForElementAndIdentifier(
        document.getElementById('topics'), 'comments--topics'
      )
      topicsController.creativeIdValue = '42'
      topicsController.topics = TOPICS
      topicsController.archivedTopics = ARCHIVED
      topicsController.mainTopicId = '1'
      topicsController.canManageTopics = true
      topicsController.showingArchived = false
      topicsController.serverLastTopicId = ''
      topicsController.renderTopics(TOPICS, true)
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
  })

  const deepLinkTo = async (topicId, { currentTopicId = '2' } = {}) => {
    const controller = buildListController({
      currentTopicId,
      topicsController,
      element: document.getElementById('chat-popup'),
    })
    global.fetch = jest.fn().mockResolvedValue(commentsResponse(topicId))
    await controller.fetchComments({ around_comment_id: 55 })
    return controller
  }

  // A collapsed archived section renders no chips, so the resolved topic would
  // be open with nothing in the strip showing which one it is.
  test('expands the archived section and marks the chip active', async () => {
    await deepLinkTo('3')

    expect(topicsController.showingArchived).toBe(true)
    const chip = topicsController.listTarget.querySelector('.topic-archived[data-id="3"]')
    expect(chip).not.toBeNull()
    expect(chip.classList.contains('active')).toBe(true)
  })

  // form_controller reads the active topic only from this event; without it a
  // reply typed under the deep link posts into the previously selected topic.
  test('dispatches change so the form follows the resolved topic', async () => {
    await deepLinkTo('3')

    expect(changeEvents.at(-1).topicId).toBe('3')
  })

  test('follows a deep link into a live topic without expanding the archived section', async () => {
    await deepLinkTo('2', { currentTopicId: '' })

    expect(changeEvents.at(-1).topicId).toBe('2')
    expect(topicsController.showingArchived).toBe(false)
  })

  // The change event reaches list_controller's own handler; it must not restart
  // the load, which would throw away the comment the deep link is scrolling to.
  test('keeps the highlight window instead of reloading from latest', async () => {
    const controller = buildListController({
      currentTopicId: '2',
      topicsController,
      element: document.getElementById('chat-popup'),
    })
    controller.handleTopicChange = CommentsListController.prototype.handleTopicChange.bind(controller)
    controller.element.addEventListener('comments--topics:change', controller.handleTopicChange)
    controller.highlightAfterLoad = 55
    controller.highlightCreativeId = '42'
    controller.resetToLatest = jest.fn()

    global.fetch = jest.fn().mockResolvedValue(commentsResponse('3'))
    await controller.fetchComments({ around_comment_id: 55 })

    expect(controller.resetToLatest).not.toHaveBeenCalled()
    expect(controller.highlightAfterLoad).toBe(55)
    expect(controller.highlightCreativeId).toBe('42')
  })
})
