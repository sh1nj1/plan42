/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const saveLastTopic = jest.fn().mockResolvedValue(undefined)

jest.unstable_mockModule('../../../lib/api/topics', () => ({
  fetchNextTopicName: jest.fn(),
  createTopicWithComments: jest.fn(),
  saveLastTopic,
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default

const TOPICS = [{ id: 1, name: 'Main' }, { id: 2, name: 'Alpha' }, { id: 3, name: 'Beta' }]

describe('TopicsController selection vs. in-flight loadTopics', () => {
  let application
  let controller
  let changeEvents

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="topics" data-controller="comments--topics" data-topic-main-text="All Messages">
        <div data-comments--topics-target="list"></div>
      </div>
    `
    Element.prototype.scrollIntoView = jest.fn()
    document.head.innerHTML = '<meta name="csrf-token" content="test-csrf">'

    application = Application.start()
    application.register('comments--topics', TopicsController)

    changeEvents = []
    document.addEventListener('comments--topics:change', (e) => changeEvents.push(e.detail))

    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
      controller = application.getControllerForElementAndIdentifier(
        document.getElementById('topics'), 'comments--topics'
      )
      controller.creativeIdValue = '42'
      controller.topics = TOPICS
      controller.archivedTopics = []
      controller.mainTopicId = '1'
      controller.canManageTopics = true
      controller.showingArchived = false
      controller.serverLastTopicId = '2'
      // The strip is on screen before any of these races start — that is what
      // makes a chip clickable, and it is what marks the pick as being about
      // creative 42.
      controller.renderTopics(TOPICS, true)
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
    delete global.fetch
    window.history.replaceState({}, '', '/')
  })

  // The user picked a topic while the strip was still fetching. The server's
  // last_topic_id still names the topic they left, because the save for the new
  // pick is debounced and has not landed. Honouring it throws the click away.
  test('a topic picked while the strip is loading survives the response', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const loading = controller.loadTopics()

    // The user clicks Beta while the fetch is in flight.
    controller.selectTopic('3')
    expect(controller.currentTopicId).toBe('3')

    resolveFetch({
      ok: true,
      status: 200,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: 2,
      }),
    })
    await loading

    expect(controller.currentTopicId).toBe('3')
    expect(changeEvents.at(-1).topicId).toBe('3')
    expect(controller.listTarget.querySelector('.topic-tag[data-id="3"]').classList)
      .toContain('active')
  })

  // Same race, one step earlier: the pick has to survive the assignment of the
  // server's answer to serverLastTopicId, not just restoreSelection().
  test('the stale server last_topic_id does not overwrite the pick', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const loading = controller.loadTopics()
    controller.selectTopic('3')

    resolveFetch({
      ok: true,
      status: 200,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: 2,
      }),
    })
    await loading

    expect(controller.serverLastTopicId).toBe('3')
  })

  // The strip can also be stale about its own creative: another member deletes
  // a topic while the chip for it is still on screen. The pick is about this
  // creative, but it names a topic that no longer exists, so keeping it would
  // fail the lookup in restoreSelection() and persist Main over the preference
  // the server actually holds.
  test('a pick naming a topic the response no longer lists yields to the answer', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const loading = controller.loadTopics()
    controller.selectTopic('3')

    resolveFetch({
      ok: true,
      status: 200,
      json: async () => ({
        topics: [{ id: 1, name: 'Main' }, { id: 2, name: 'Alpha' }],
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: 2,
      }),
    })
    await loading

    expect(controller.currentTopicId).toBe('2')
  })

  // All Messages carries no topic id, so nothing about it can be read off the
  // saved preference — but it is still a pick, and a landing load must not undo
  // it any more than it may undo a chip click.
  describe('an All Messages pick while the strip is loading', () => {
    const respond = (resolveFetch) => resolveFetch({
      ok: true,
      status: 200,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: 2,
      }),
    })

    test('survives the response', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')

      respond(resolveFetch)
      await loading

      expect(controller.currentTopicId).toBe('')
      expect(controller.listTarget.querySelector('.topic-all-messages').classList)
        .toContain('active')
    })

    // The revert this PR is about is the message list snapping back, so the
    // change event matters as much as the strip: nothing may re-announce the
    // topic the user just left.
    test('does not re-announce the topic the user left', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')

      respond(resolveFetch)
      await loading

      expect(changeEvents.at(-1).topicId).toBe('')
    })

    // ...and the debounced save must still record the pick, not the stale
    // answer that overtook it.
    test('persists All Messages, not the stale answer', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')

      respond(resolveFetch)
      await loading
      await controller.flushSaveLastTopic(controller.currentTopicId)

      expect(saveLastTopic).toHaveBeenLastCalledWith('42', null)
    })
  })

  // The legacy per-browser preference is adopted on the first load that finds
  // the server holding nothing. A winning empty pick leaves the server value
  // empty on purpose, which reads exactly the same to the migration — so it
  // would hand the user back the topic they just left, by another route.
  describe('a winning empty pick against the localStorage migration', () => {
    const LEGACY_KEY = 'collavre_creative_42_last_topic'

    const respond = (resolveFetch, lastTopicId) => resolveFetch({
      ok: true,
      status: 200,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: lastTopicId,
      }),
    })

    afterEach(() => localStorage.clear())

    test('the migration does not restore the legacy topic over the pick', async () => {
      localStorage.setItem(LEGACY_KEY, '2')
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')

      respond(resolveFetch, 2)
      await loading

      expect(controller.currentTopicId).toBe('')
      expect(controller.listTarget.querySelector('.topic-all-messages').classList)
        .toContain('active')
    })

    test('the legacy topic is not persisted as the preference either', async () => {
      localStorage.setItem(LEGACY_KEY, '2')
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')

      respond(resolveFetch, null)
      await loading
      await controller.flushSaveLastTopic(controller.currentTopicId)

      expect(saveLastTopic).not.toHaveBeenCalledWith('42', '2')
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', null)
    })

    // The pick supersedes the legacy value, so the key has served its purpose
    // and must not be left behind to re-apply on the next load.
    test('the legacy key is still cleared', async () => {
      localStorage.setItem(LEGACY_KEY, '2')
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')

      respond(resolveFetch, null)
      await loading

      expect(localStorage.getItem(LEGACY_KEY)).toBeNull()
    })

    // ...and the migration itself is untouched when no pick is racing it.
    test('an unraced load still migrates the legacy topic', async () => {
      localStorage.setItem(LEGACY_KEY, '2')
      controller.serverLastTopicId = ''
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          topics: TOPICS,
          archived_topics: [],
          can_manage: true,
          main_topic_id: 1,
          last_topic_id: null,
        }),
      })

      await controller.loadTopics()

      expect(controller.currentTopicId).toBe('2')
      expect(saveLastTopic).toHaveBeenCalledWith('42', '2')
      expect(localStorage.getItem(LEGACY_KEY)).toBeNull()
    })
  })

  // A pick can only outrank the response if it was made against the strip of
  // the creative the response describes. Switching creatives leaves the
  // previous creative's chips on screen until the new strip lands, so a click
  // in that window is not intent about the creative being loaded.
  describe('a pick against the previous creative\'s strip', () => {
    const OTHER_TOPICS = [{ id: 10, name: 'Main' }, { id: 11, name: 'Gamma' }]

    const switchTo = (creativeId) => {
      controller.subscribe = jest.fn()
      return controller.onPopupOpened({ creativeId })
    }

    const otherCreativeResponse = {
      ok: true,
      status: 200,
      json: async () => ({
        topics: OTHER_TOPICS,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 10,
        last_topic_id: 11,
      }),
    }

    test('does not discard the new creative\'s last_topic_id', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const switching = switchTo('99')
      // Beta belongs to creative 42; its chip is still rendered.
      controller.selectTopic('3')

      resolveFetch(otherCreativeResponse)
      await switching

      expect(controller.serverLastTopicId).toBe('11')
      expect(controller.currentTopicId).toBe('11')
    })

    test('does not persist Main as the new creative\'s preference', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const switching = switchTo('99')
      controller.selectTopic('3')

      resolveFetch(otherCreativeResponse)
      await switching
      await controller.flushSaveLastTopic(controller.currentTopicId)

      expect(saveLastTopic).toHaveBeenLastCalledWith('99', '11')
    })

    // An empty pick is authoritative for the creative whose strip it was made
    // against, and this one was made against the previous creative's — so the
    // creative being opened still resolves to its own saved topic.
    test('an empty pick does not suppress the response either', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const switching = switchTo('99')
      controller.selectTopic('')

      resolveFetch(otherCreativeResponse)
      await switching

      expect(controller.currentTopicId).toBe('11')
    })
  })

  // A load that starts *after* the pick is not racing it, so its answer wins
  // normally — otherwise a creative switch could never move the selection.
  test('a load started after the pick still restores the server selection', async () => {
    controller.selectTopic('3')

    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: 2,
      }),
    })

    await controller.loadTopics()

    expect(controller.currentTopicId).toBe('2')
  })
})

// The deep-link override and ?topic_id= both outrank the saved preference in
// the getter, so a pick that only writes the preference never becomes the
// answer — the next render lights the old chip and the next restore navigates
// back to it.
describe('TopicsController selection vs. higher-priority selection sources', () => {
  let application
  let controller

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="topics" data-controller="comments--topics" data-topic-main-text="All Messages">
        <div data-comments--topics-target="list"></div>
      </div>
    `
    Element.prototype.scrollIntoView = jest.fn()

    application = Application.start()
    application.register('comments--topics', TopicsController)

    return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
      controller = application.getControllerForElementAndIdentifier(
        document.getElementById('topics'), 'comments--topics'
      )
      controller.creativeIdValue = '42'
      controller.topics = TOPICS
      controller.archivedTopics = []
      controller.mainTopicId = '1'
      controller.canManageTopics = true
      controller.showingArchived = false
      controller.serverLastTopicId = ''
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
    window.history.replaceState({}, '', '/')
  })

  test('a pick supersedes a deep-link override for a different topic', () => {
    controller.setOverrideTopicId('2')

    controller.selectTopic('3')

    expect(controller.currentTopicId).toBe('3')
  })

  test('restoreSelection after such a pick stays on the picked topic', () => {
    controller.setOverrideTopicId('2')
    controller.selectTopic('3')

    controller.restoreSelection()
    controller.renderTopics(controller.topics, controller.canManageTopics)

    expect(controller.currentTopicId).toBe('3')
    expect(controller.listTarget.querySelector('.topic-tag[data-id="3"]').classList)
      .toContain('active')
  })

  test('an override agreeing with the pick is kept so it can still outrank the server', () => {
    controller.setOverrideTopicId('3')

    controller.selectTopic('3')

    expect(controller.overrideTopicId).toBe('3')
    controller.serverLastTopicId = '2' // as a later loadTopics() would write it
    expect(controller.currentTopicId).toBe('3')
  })

  test('a pick drops a ?topic_id= naming a different topic', () => {
    window.history.replaceState({}, '', '/creatives/42?topic_id=2')

    controller.selectTopic('3')

    expect(controller.currentTopicId).toBe('3')
    expect(new URLSearchParams(window.location.search).get('topic_id')).toBeNull()
  })

  test('a pick keeps a ?topic_id= naming the topic it selected', () => {
    window.history.replaceState({}, '', '/creatives/42?topic_id=3')

    controller.selectTopic('3')

    expect(new URLSearchParams(window.location.search).get('topic_id')).toBe('3')
  })

  test('selecting All Messages drops a ?topic_id= too', () => {
    window.history.replaceState({}, '', '/creatives/42?topic_id=2')

    controller.selectTopic('')

    expect(controller.currentTopicId).toBe('')
    expect(new URLSearchParams(window.location.search).get('topic_id')).toBeNull()
  })

  test('selecting All Messages drops a deep-link override too', () => {
    controller.setOverrideTopicId('2')

    controller.selectTopic('')

    expect(controller.currentTopicId).toBe('')
  })
})
