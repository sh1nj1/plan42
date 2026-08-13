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

    test('toggling stale archived topics does not make their strip look current', async () => {
      controller.archivedTopics = [{ id: 4, name: 'Archived Alpha' }]
      controller.renderTopics(TOPICS, true)
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const switching = switchTo('99')
      controller.toggleArchivedTopics({ stopPropagation: jest.fn() })
      controller.selectTopic('')

      resolveFetch(otherCreativeResponse)
      await switching

      expect(controller.serverLastTopicId).toBe('11')
      expect(controller.currentTopicId).toBe('11')
    })
  })

  // Not every write to the selection is a pick. loadTopics() empties the strip
  // for the duration of its fetch, so any re-render landing in that window
  // restores against an empty topic list and falls back to Main. That fallback
  // is derived from state the load is about to replace — treating it as intent
  // newer than the answer suppresses the very value it was derived from.
  describe('a programmatic restore while the strip is loading', () => {
    const NEW_TOPIC = { id: 4, name: 'Delta' }

    const respond = (resolveFetch, topics = TOPICS) => resolveFetch({
      ok: true,
      status: 200,
      json: async () => ({
        topics,
        archived_topics: [],
        can_manage: true,
        main_topic_id: 1,
        last_topic_id: 2,
      }),
    })

    // Another member creates a topic mid-load. handleTopicMessage() renders it
    // on its own — this.topics was emptied — and restoreSelection() cannot find
    // the saved topic among the one topic on screen.
    const broadcastCreate = (userId = '99') => controller.handleTopicMessage({
      action: 'created', topic: NEW_TOPIC, user_id: userId,
    })

    afterEach(() => { delete document.body.dataset.currentUserId })

    test('does not suppress the response it was derived from', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      broadcastCreate()
      expect(controller.currentTopicId).toBe('1') // fell back to Main

      respond(resolveFetch)
      await loading

      expect(controller.currentTopicId).toBe('2')
      expect(controller.listTarget.querySelector('.topic-tag[data-id="2"]').classList)
        .toContain('active')
    })

    test('does not persist Main over the saved preference', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      broadcastCreate()

      respond(resolveFetch)
      await loading
      await controller.flushSaveLastTopic(controller.currentTopicId)

      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '2')
    })

    // A real pick has already won this load. A later restore is derived from
    // the interim one-topic strip, so it may fall back to Main, but it must not
    // replace the id associated with that authoritative pick.
    test('retains a picked topic across an interim restore', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('3')
      broadcastCreate()
      expect(controller.currentTopicId).toBe('1')

      respond(resolveFetch)
      await loading

      expect(controller.currentTopicId).toBe('3')
      await controller.flushSaveLastTopic(controller.currentTopicId)
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3')
    })

    test('re-dispatches a picked All Messages after an interim restore', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

      const loading = controller.loadTopics()
      controller.selectTopic('')
      broadcastCreate()
      expect(changeEvents.at(-1).topicId).toBe('1')

      respond(resolveFetch)
      await loading

      expect(controller.currentTopicId).toBe('')
      expect(changeEvents.at(-1).topicId).toBe('')
      expect(controller.listTarget.querySelector('.topic-tag[data-id=""]').classList)
        .toContain('active')
    })

    // The fallback is not the user moving off the link either, so it must not
    // consume the sources that outrank the preference. They are one-shot: once
    // released, not even a reload gets the linked conversation back.
    test('does not consume a deep-link override', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))
      controller.setOverrideTopicId('3')

      const loading = controller.loadTopics()
      broadcastCreate()

      respond(resolveFetch)
      await loading

      expect(controller.overrideTopicId).toBe('3')
      expect(controller.currentTopicId).toBe('3')
    })

    test('does not strip ?topic_id=', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))
      window.history.replaceState({}, '', '/creatives/42?topic_id=3')

      const loading = controller.loadTopics()
      broadcastCreate()

      respond(resolveFetch)
      await loading

      expect(new URLSearchParams(window.location.search).get('topic_id')).toBe('3')
      expect(controller.currentTopicId).toBe('3')
    })

    // The fallback is not the only restore that can land mid-load. archivedTopics
    // outlives the emptied strip, so a preference naming an archived topic is
    // still found — and re-selecting it is no more a pick than falling back to
    // Main is. Left as one, it discards a preference another session moved and
    // writes the local value back over it.
    test('re-selecting the topic already held does not suppress the response', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))
      controller.archivedTopics = [{ id: 5, name: 'Archived' }]
      controller.serverLastTopicId = '5'

      const loading = controller.loadTopics()
      broadcastCreate()
      expect(controller.currentTopicId).toBe('5') // found among the archived

      resolveFetch({
        ok: true,
        status: 200,
        json: async () => ({
          topics: TOPICS,
          archived_topics: [{ id: 5, name: 'Archived' }],
          can_manage: true,
          main_topic_id: 1,
          last_topic_id: 2,
        }),
      })
      await loading
      await controller.flushSaveLastTopic(controller.currentTopicId)

      expect(controller.currentTopicId).toBe('2')
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '2')
    })

    // The same broadcast for a topic this user created elsewhere auto-selects
    // it, and that is intent — it still has to outrank the landing answer.
    test('the auto-select of the user\'s own new topic still outranks the response', async () => {
      let resolveFetch
      global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))
      document.body.dataset.currentUserId = '7'

      const loading = controller.loadTopics()
      broadcastCreate('7')

      respond(resolveFetch, [...TOPICS, NEW_TOPIC])
      await loading

      expect(controller.currentTopicId).toBe('4')
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

// last_topic_changed is another session of the same user moving the saved
// preference. It is not a click in this popup, so it must not consume the
// deep-link sources this popup was opened on — they outrank the preference by
// design, and they are gone for good once released.
describe('TopicsController deep-link sources vs. a preference broadcast', () => {
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
      controller.renderTopics(TOPICS, true)
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
    window.history.replaceState({}, '', '/')
  })

  test('a broadcast does not consume a deep-link override', () => {
    controller.setOverrideTopicId('3')

    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

    expect(controller.overrideTopicId).toBe('3')
    expect(controller.currentTopicId).toBe('3')
  })

  test('a broadcast does not strip ?topic_id=', () => {
    window.history.replaceState({}, '', '/creatives/42?topic_id=3')

    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

    expect(new URLSearchParams(window.location.search).get('topic_id')).toBe('3')
    expect(controller.currentTopicId).toBe('3')
  })

  test('a broadcast leaves the linked topic selected in the strip', () => {
    controller.setOverrideTopicId('3')

    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })
    controller.restoreSelection()

    expect(controller.listTarget.querySelector('.topic-tag[data-id="3"]').classList)
      .toContain('active')
    expect(controller.listTarget.querySelector('.topic-tag[data-id="2"]').classList)
      .not.toContain('active')
  })

  test('the broadcast preference is still recorded behind the deep link', () => {
    controller.setOverrideTopicId('3')

    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

    expect(controller.serverLastTopicId).toBe('2')
    // Releasing the link hands the popup back to the preference the other
    // session set, rather than to a value this popup never heard about.
    controller.clearOverrideTopicId()
    expect(controller.currentTopicId).toBe('2')
  })

  // comments_controller sends X-Topic-Id as effective_topic_id.to_s, so a
  // comment that belongs to no topic resolves the deep link to All Messages and
  // list_controller sets the override to "". It outranks the preference exactly
  // like a named one — truthiness is the wrong test for "is a link set".
  test('a broadcast does not consume a deep link that resolved to All Messages', () => {
    controller.setOverrideTopicId('')

    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

    expect(controller.overrideTopicId).toBe('')
    expect(controller.currentTopicId).toBe('')
  })

  test('a broadcast still moves the selection when no deep link outranks it', () => {
    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

    expect(controller.serverLastTopicId).toBe('2')
    expect(controller.currentTopicId).toBe('2')
    expect(controller.listTarget.querySelector('.topic-tag[data-id="2"]').classList)
      .toContain('active')
  })

  test('a pick after a broadcast still supersedes the deep link', () => {
    controller.setOverrideTopicId('3')
    controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

    controller.selectTopic('1')

    expect(controller.currentTopicId).toBe('1')
  })

  // Every selection schedules a save, restores included, and the save is
  // debounced by 500ms. Accepting a broadcast without following it leaves that
  // timer holding the topic the link put us on, so it lands afterwards and
  // writes the deep link back over the preference the other session just set.
  describe('a pending save against an accepted broadcast', () => {
    beforeEach(() => {
      jest.useFakeTimers()
    })

    afterEach(() => {
      jest.runOnlyPendingTimers()
      jest.useRealTimers()
    })

    test('the deep link is not written back over the broadcast preference', () => {
      window.history.replaceState({}, '', '/creatives/42?topic_id=3')
      controller.restoreSelection()

      controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })
      jest.advanceTimersByTime(500)

      expect(saveLastTopic).not.toHaveBeenCalledWith('42', '3')
    })

    // The broadcast is the preference now; nothing this popup had queued
    // beforehand describes it, so nothing queued beforehand may be sent.
    test('no save at all follows an accepted broadcast', () => {
      controller.setOverrideTopicId('3')
      controller.restoreSelection()

      controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })
      jest.advanceTimersByTime(500)

      expect(saveLastTopic).not.toHaveBeenCalled()
      expect(controller.serverLastTopicId).toBe('2')
    })

    // Cancelling is scoped to the accepted broadcast. A selection the user
    // makes afterwards is theirs, and still has to reach the server.
    test('a pick after the broadcast still saves', () => {
      controller.setOverrideTopicId('3')
      controller.restoreSelection()
      controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

      controller.selectTopic('1')
      jest.advanceTimersByTime(500)

      expect(saveLastTopic).toHaveBeenCalledWith('42', '1')
    })

    // With no link to hold the view, the broadcast is followed, and following
    // it re-arms the debounce with the broadcast's own value — so the timer
    // must not be left cancelled on that path.
    test('a followed broadcast still persists its own value', () => {
      controller.restoreSelection()

      controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })
      jest.advanceTimersByTime(500)

      expect(saveLastTopic).toHaveBeenCalledWith('42', '2')
    })

    test('a later restore leaves the broadcast preference behind the deep link', () => {
      controller.setOverrideTopicId('3')
      controller.handleTopicMessage({ action: 'last_topic_changed', last_topic_id: 2 })

      controller.handleTopicMessage({ action: 'updated', topic: { id: 1, name: 'Renamed Main' } })
      jest.advanceTimersByTime(500)

      expect(controller.currentTopicId).toBe('3')
      expect(controller.serverLastTopicId).toBe('2')
      expect(saveLastTopic).not.toHaveBeenCalledWith('42', '3')
    })
  })
})
