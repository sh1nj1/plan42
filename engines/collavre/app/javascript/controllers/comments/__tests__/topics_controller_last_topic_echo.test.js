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

// Captures the lifecycle callbacks the controller registers, so a test can fire
// the ones ActionCable fires on a dropped or refused connection.
let subscriptionCallbacks
const createSubscription = jest.fn((_identifier, callbacks) => {
  subscriptionCallbacks = callbacks
  return { unsubscribe: jest.fn() }
})

jest.unstable_mockModule('../../../services/cable', () => ({
  createSubscription,
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

  // unsubscribe() is only the deliberate exit. A connection that drops or a
  // subscription the server refuses loses the same echoes without any of that
  // running, and ActionCable replays nothing on reconnect — so a claim left
  // behind waits for a message that will never come.
  describe('claims against a subscription that goes away on its own', () => {
    // Delivered the way the real ones are, through the subscription itself.
    const deliver = (lastTopicId) => subscriptionCallbacks.received({
      action: 'last_topic_changed',
      last_topic_id: lastTopicId,
    })

    beforeEach(() => {
      subscriptionCallbacks = undefined
      controller.subscribe()
    })

    test('a dropped connection drops outstanding claims', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      subscriptionCallbacks.disconnected()
      // Reconnected, and another session moves the preference to Alpha.
      controller.selectTopic('3')
      deliver('2')

      expect(controller.currentTopicId).toBe('2')
    })

    test('a refused subscription drops outstanding claims', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      subscriptionCallbacks.rejected()
      controller.selectTopic('3')
      deliver('2')

      expect(controller.currentTopicId).toBe('2')
    })

    // The claim is only dropped by those two — an ordinary echo on a healthy
    // subscription still settles the save that is waiting for it.
    test('an echo on a live subscription is still consumed', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      controller.selectTopic('3')
      deliver('2')

      expect(controller.currentTopicId).toBe('3')
    })
  })

  // Two PATCHes in flight at once are answered — and broadcast — in whatever
  // order the server finishes them, which the head-of-queue check reads as
  // "not ours". The claim it skips is then owed a message that has already
  // been and gone, and it swallows the next real update naming that topic.
  // Sending one save at a time is what makes the queue order true.
  describe('a save made while another is still in flight', () => {
    let resolveFirst

    // Both picks are made back to back, as a fast second click does. The await
    // only lets the head of the queue issue its request — resolveFirst is the
    // handle on it, and is only assigned once it has.
    const startTwoSaves = async () => {
      resolveFirst = null
      saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve }))
      controller.selectTopic('2')
      const first = controller.flushSaveLastTopic('2')
      controller.selectTopic('3')
      const second = controller.flushSaveLastTopic('3')
      await Promise.resolve()
      expect(resolveFirst).toEqual(expect.any(Function))
      return [first, second]
    }

    test('waits for the one in flight instead of racing it', async () => {
      const pending = await startTwoSaves()

      expect(saveLastTopic).toHaveBeenCalledTimes(1)
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '2')

      resolveFirst(true)
      await Promise.all(pending)

      expect(saveLastTopic).toHaveBeenCalledTimes(2)
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3')
    })

    // With the sends ordered, the echoes are too: the first save's broadcast is
    // emitted before the second save is even sent. Both are then claimed and
    // consumed in turn, and nothing is left to swallow a later update.
    test('leaves no claim behind once both echoes land', async () => {
      const pending = await startTwoSaves()
      echo('2')
      resolveFirst(true)
      await Promise.all(pending)
      echo('3')

      // The user moves on, and another session picks Beta for real.
      controller.selectTopic('')
      echo('3')

      expect(controller.currentTopicId).toBe('3')
    })

    // A save that fails still has to hand the queue on, or every later pick is
    // stranded behind it and never reaches the server at all.
    test('a rejected save does not strand the one behind it', async () => {
      let rejectFirst
      saveLastTopic.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectFirst = reject }))
      controller.selectTopic('2')
      const first = controller.flushSaveLastTopic('2')
      controller.selectTopic('3')
      const second = controller.flushSaveLastTopic('3')
      await Promise.resolve()

      rejectFirst(new Error('network'))
      await Promise.all([first, second])

      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3')
      // Nothing was broadcast for it either, so its claim goes with it.
      controller.selectTopic('')
      echo('2')
      expect(controller.currentTopicId).toBe('2')
    })
  })
})
