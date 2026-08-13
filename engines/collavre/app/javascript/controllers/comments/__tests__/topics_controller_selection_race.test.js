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
