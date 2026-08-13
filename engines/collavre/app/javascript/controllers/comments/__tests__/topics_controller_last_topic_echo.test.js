/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

// The real helper resolves to response.ok — never throws, never undefined.
const saveLastTopic = jest.fn().mockResolvedValue(true)

jest.unstable_mockModule('../../../lib/api/topics', () => ({
  fetchNextTopicName: jest.fn(),
  createTopicWithComments: jest.fn(),
  saveLastTopic,
}))

const { Application } = await import('@hotwired/stimulus')
const TopicsController = (await import('../topics_controller')).default

const TOPICS = [{ id: 1, name: 'Main' }, { id: 2, name: 'Alpha' }, { id: 3, name: 'Beta' }]

// update_last_topic broadcasts to every session of the current user, including
// the one that just saved. The echo carries no sender, so a client cannot tell
// its own save coming back from another tab's change — and the echo lands after
// the save that produced it, which is exactly the window a fast second pick
// falls into.
describe('TopicsController vs. the echo of its own last_topic save', () => {
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

  const echo = (lastTopicId) => controller.handleTopicMessage({
    action: 'last_topic_changed',
    last_topic_id: lastTopicId,
  })

  // Pick Alpha, let its debounced save go out, then pick Beta before the echo
  // for Alpha gets back. The echo names the topic the user has just left.
  test('a pick made before the echo lands is not reverted by it', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.selectTopic('3')
    echo('2')

    expect(controller.currentTopicId).toBe('3')
    expect(changeEvents.at(-1).topicId).toBe('3')
    expect(controller.listTarget.querySelector('.topic-tag[data-id="3"]').classList)
      .toContain('active')
  })

  // ...and the revert must not be written back as the preference either.
  test('the stale echo is not persisted over the pick', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.selectTopic('3')
    echo('2')
    await controller.flushSaveLastTopic(controller.currentTopicId)

    expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3')
  })

  // Same race for All Messages, which the strip renders as its own chip.
  test('an All Messages pick is not reverted by the echo of the topic it left', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.selectTopic('')
    echo('2')

    expect(controller.currentTopicId).toBe('')
  })

  // The point of the broadcast is cross-tab sync, and that has to keep working:
  // a change this client did not make is real news, not an echo.
  test('a change from another session is still applied', () => {
    echo('3')

    expect(controller.currentTopicId).toBe('3')
    expect(changeEvents.at(-1).topicId).toBe('3')
  })

  test('another session is still applied after this one has saved something else', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    echo('3')

    expect(controller.currentTopicId).toBe('3')
  })

  // A rejected save broadcasts nothing — update_last_topic returns before the
  // broadcast on a denied read or a topic outside the creative — so the client
  // must not go on waiting for an echo that is never coming.
  test('a save that did not land leaves no claim on a later echo', async () => {
    saveLastTopic.mockResolvedValueOnce(false)
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.selectTopic('3')
    // Another session moves the preference to Alpha for real.
    echo('2')

    expect(controller.currentTopicId).toBe('2')
  })

  // Messages missed while disconnected are gone, and the stream is per
  // creative, so claims must not outlive the subscription that would settle
  // them — a stale one would swallow the next unrelated broadcast.
  test('leaving the stream drops outstanding claims', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.unsubscribe()
    controller.selectTopic('3')
    echo('2')

    expect(controller.currentTopicId).toBe('2')
  })
})
