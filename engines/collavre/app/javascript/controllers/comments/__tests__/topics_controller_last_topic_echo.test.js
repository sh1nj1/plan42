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
// the one that just saved, and the echo lands after the save that produced it —
// exactly the window a fast second pick falls into. Telling the echo apart from
// a sibling session's change is what the client_id on the broadcast is for; the
// topic id cannot do it, two sessions can pick the same topic at once.
describe('TopicsController vs. the echo of its own last_topic save', () => {
  let application
  let controller
  let changeEvents
  let originalFetch

  beforeEach(() => {
    originalFetch = global.fetch
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
    controller.cancelPendingSaveLastTopic()
    global.fetch = originalFetch
    document.body.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
    window.history.replaceState({}, '', '/')
  })

  // A broadcast from some other session of this user: it names a topic and
  // nothing else. Without a client_id it cannot have come from this client.
  const echo = (lastTopicId, clientId, lastTopicRevision) => controller.handleTopicMessage({
    action: 'last_topic_changed',
    last_topic_id: lastTopicId,
    ...(lastTopicRevision === undefined ? {} : { last_topic_revision: lastTopicRevision }),
    ...(clientId === undefined ? {} : { client_id: clientId }),
  })

  // The echo of a save this client made: the server hands back the id that
  // save was sent with, which is what makes it identifiable as ours.
  const clientIdFor = (lastTopicId) => {
    const call = saveLastTopic.mock.calls.find(c => String(c[1] ?? '') === String(lastTopicId ?? ''))
    return call && call[2]
  }

  const selfEcho = (lastTopicId, lastTopicRevision) => echo(lastTopicId, clientIdFor(lastTopicId), lastTopicRevision)

  test('does not recreate acknowledgement metadata when the echo arrives before the response', async () => {
    let resolveSave
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()
    const clientId = clientIdFor('2')

    echo('2', clientId)
    expect(controller.pendingSelfEchoes).not.toContain(clientId)

    resolveSave(true)
    await save

    expect(controller.pendingSelfEchoAcknowledgementVersions.has(clientId)).toBe(false)
  })

  test('an early echo keeps its save order until an older load is processed', async () => {
	let resolveSave
	let resolveSnapshot
	controller.lastKnownRemoteTopicId = '1'
	saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
	global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))

	const load = controller.loadTopics()
	controller.selectTopic('2')
	const save = controller.flushSaveLastTopic('2')
	await Promise.resolve()

	selfEcho('2')
	resolveSave(true)
	await save
	resolveSnapshot({
		ok: true,
		json: async () => ({
			topics: TOPICS,
			archived_topics: [],
			can_manage: true,
			last_topic_id: '1',
			main_topic_id: '1',
			effective_creative_id: '42',
		}),
	})
	await load

	expect(controller.currentTopicId).toBe('2')
	expect(controller.serverLastTopicId).toBe('2')
	expect(controller.pendingSelfEchoAcknowledgementVersions.has(clientIdFor('2'))).toBe(false)
  })

	test('an early echo keeps its save order for a reopened load with a later request number', async () => {
		let resolveSave
		let resolveSnapshot
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()

		controller.onPopupClosed()
		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))
		const reopen = controller.onPopupOpened({ creativeId: '42' })
		await Promise.resolve()

		selfEcho('2')
		resolveSave(true)
		await save
		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await reopen

		expect(controller.currentTopicId).toBe('2')
		expect(controller.serverLastTopicId).toBe('2')
	})

	test('a closed save yields when its early echo precedes a newer reopen snapshot', async () => {
		let resolveSave
		let resolveSnapshot
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		controller.onPopupClosed()

		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))
		const reopen = controller.onPopupOpened({ creativeId: '42' })
		await Promise.resolve()

		selfEcho('2')
		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '3',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await reopen

		expect(controller.currentTopicId).toBe('3')
		resolveSave(true)
		await save
	})

	test('a newer ABA reopen snapshot yields to the server revision, not its repeated topic id', async () => {
		let resolveSave
		let resolveSnapshot
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		controller.onPopupClosed()

		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))
		const reopen = controller.onPopupOpened({ creativeId: '42' })
		await Promise.resolve()

		// The server accepted Alpha, then a sibling session deliberately chose
		// Main again. The values form an ABA sequence, but revision [5, 2] is
		// newer than the self-echo's [5, 1].
		selfEcho('2', [5, 1])
		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				last_topic_revision: [5, 2],
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await reopen

		expect(controller.currentTopicId).toBe('1')
		resolveSave(true)
		await save
	})

	test('a PATCH acknowledgement orders a delayed ABA snapshot before its self-echo', async () => {
		let resolveSave
		let resolveSnapshot
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()

		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))
		const load = controller.loadTopics()
		await Promise.resolve()

		// This client's Alpha commit is revision [5, 1]. Before its self-echo
		// arrives, another session selects Main again at [5, 2]. The request
		// response must preserve [5, 1] so the GET is not mistaken for the
		// stale Main snapshot from before the local save.
		resolveSave({ success: true, lastTopicRevision: [5, 1] })
		await save
		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				last_topic_revision: [5, 2],
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await load

		expect(controller.currentTopicId).toBe('1')
	})

	test('waits for a closed pending save before reconciling a revisioned ABA snapshot', async () => {
		let resolveSave
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
		global.fetch = jest.fn()
			.mockResolvedValueOnce({
				ok: true,
				json: async () => ({
					topics: TOPICS,
					archived_topics: [],
					can_manage: true,
					last_topic_id: '1',
					last_topic_revision: [5, 2],
					main_topic_id: '1',
					effective_creative_id: '42',
				}),
			})
			.mockResolvedValueOnce({
				ok: true,
				json: async () => ({
					topics: TOPICS,
					archived_topics: [],
					can_manage: true,
					last_topic_id: '1',
					last_topic_revision: [5, 2],
					main_topic_id: '1',
					effective_creative_id: '42',
				}),
			})

		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		controller.onPopupClosed()
		await controller.onPopupOpened({ creativeId: '42' })

		// Alpha's response and echo are both late, so the Main snapshot could
		// either predate Alpha or be a sibling's later ABA write. Do not replay
		// Alpha through that ambiguity.
		expect(controller.currentTopicId).toBe('2')
		expect(saveLastTopic).toHaveBeenCalledTimes(1)

		resolveSave({ success: true, lastTopicRevision: [5, 1] })
		await save
		await new Promise(resolve => setTimeout(resolve, 0))

		expect(global.fetch).toHaveBeenCalledTimes(2)
		expect(controller.currentTopicId).toBe('1')
	})

	test('a committed revision outranks a snapshot with a different predecessor topic', async () => {
		let resolveSave
		let resolveSnapshot
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))

		controller.selectTopic('3')
		const save = controller.flushSaveLastTopic('3')
		await Promise.resolve()
		const load = controller.loadTopics()
		await Promise.resolve()

		// Another session chose Alpha after this client observed Main, but before
		// the local Beta save committed. The acknowledgement proves Beta's [5, 2]
		// revision is newer than the GET's Alpha [5, 1] snapshot, even though
		// Alpha is not Beta's predecessor topic.
		resolveSave({ success: true, lastTopicRevision: [5, 2] })
		await save
		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '2',
				last_topic_revision: [5, 1],
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await load

		expect(controller.currentTopicId).toBe('3')
		expect(controller.serverLastTopicId).toBe('3')
	})

	test('an early linked-shell echo advances the resolved stream baseline', async () => {
		let resolveSave
		let resolveSnapshot
		controller.creativeIdValue = '77'
		controller.element.dataset.effectiveCreativeId = '42'
		controller.setLastKnownRemoteTopicId('42', '1')
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		controller.onPopupClosed()
		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))
		const reopen = controller.onPopupOpened({ creativeId: '77' })
		await Promise.resolve()

		selfEcho('2', [5, 1])
		expect(controller.lastKnownRemoteTopicIdFor('42')).toBe('2')
		expect(controller.lastKnownRemoteTopicIdFor('77')).toBeUndefined()

		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '2',
				last_topic_revision: [5, 1],
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await reopen
		resolveSave(true)
		await save
	})

  // Pick Alpha, let its debounced save go out, then pick Beta before the echo
  // for Alpha gets back. The echo names the topic the user has just left.
  test('a pick made before the echo lands is not reverted by it', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.selectTopic('3')
    selfEcho('2')

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
    selfEcho('2')
    await controller.flushSaveLastTopic(controller.currentTopicId)

    expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3', expect.any(String))
  })

  // Same race for All Messages, which the strip renders as its own chip.
  test('an All Messages pick is not reverted by the echo of the topic it left', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.selectTopic('')
    selfEcho('2')

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

  // The stream is per creative, so leaving it for another means the echoes it
  // owed us are not coming. Nothing can settle those claims; they go with it.
  test('leaving the stream drops outstanding claims', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.unsubscribe()

    expect(controller.pendingSelfEchoes).toHaveLength(0)
    controller.selectTopic('3')
    echo('2')
    expect(controller.currentTopicId).toBe('2')
  })

  test('closing and reopening the same creative keeps an in-flight claim', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.onPopupClosed()
    controller.loadTopics = jest.fn()
    controller.onPopupOpened({ creativeId: '42' })
    controller.selectTopic('3')
    selfEcho('2')

    expect(controller.currentTopicId).toBe('3')
  })

  test('a reopen does not restore a stale preference over its pending save', async () => {
    let resolveSave
    controller.lastKnownRemoteTopicId = '1'
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
    controller.selectTopic('2')
    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()

    controller.onPopupClosed()
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        last_topic_id: '1',
        main_topic_id: '1',
        effective_creative_id: '42',
      }),
    })
    await controller.onPopupOpened({ creativeId: '42' })

    expect(controller.currentTopicId).toBe('2')
    resolveSave(true)
    await save
    await controller.flushSaveLastTopic(controller.currentTopicId)
    expect(saveLastTopic).toHaveBeenLastCalledWith('42', '2', expect.any(String))

    selfEcho('2')
    expect(controller.currentTopicId).toBe('2')
  })

  test('a stale reopen snapshot still yields to a save acknowledged after its load began', async () => {
    let resolveSave
    let resolveSnapshot
    controller.lastKnownRemoteTopicId = '1'
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))

    controller.selectTopic('2')
    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()
    controller.onPopupClosed()
    const reopen = controller.onPopupOpened({ creativeId: '42' })
    await Promise.resolve()

    resolveSave(true)
    await save
    resolveSnapshot({
      ok: true,
      json: async () => ({
		topics: TOPICS,
		archived_topics: [],
		can_manage: true,
		last_topic_id: '1',
		main_topic_id: '1',
		effective_creative_id: '42',
      }),
    })
    await reopen

    expect(controller.currentTopicId).toBe('2')
    expect(controller.serverLastTopicId).toBe('2')
  })

  test('a stale reopen snapshot yields to every save acknowledged after its load began', async () => {
    let resolveAlphaSave
    let resolveBetaSave
    let resolveSnapshot
    controller.lastKnownRemoteTopicId = '1'
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveAlphaSave = resolve }))
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveBetaSave = resolve }))
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))

    controller.selectTopic('2')
    const alphaSave = controller.flushSaveLastTopic('2')
    await Promise.resolve()
    controller.selectTopic('3')
    const betaSave = controller.flushSaveLastTopic('3')
    controller.onPopupClosed()
    const reopen = controller.onPopupOpened({ creativeId: '42' })
    await Promise.resolve()

    resolveAlphaSave(true)
    await alphaSave
    await Promise.resolve()
    resolveBetaSave(true)
    await betaSave
    resolveSnapshot({
      ok: true,
      json: async () => ({
		topics: TOPICS,
		archived_topics: [],
		can_manage: true,
		last_topic_id: '1',
		main_topic_id: '1',
		effective_creative_id: '42',
      }),
    })
    await reopen

    expect(controller.currentTopicId).toBe('3')
    expect(controller.serverLastTopicId).toBe('3')
  })

  test('a stale load does not roll back the baseline for a later closed save', async () => {
		let resolveSnapshot
		let resolveBetaSave
		controller.lastKnownRemoteTopicId = '1'
		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))

		const staleLoad = controller.loadTopics()
		controller.selectTopic('2')
		await controller.flushSaveLastTopic('2')

		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await staleLoad
		expect(controller.currentTopicId).toBe('2')
		expect(controller.lastKnownRemoteTopicId).toBe('2')

		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveBetaSave = resolve }))
		controller.selectTopic('3')
		const betaSave = controller.flushSaveLastTopic('3')
		await Promise.resolve()
		controller.onPopupClosed()
		global.fetch = jest.fn().mockResolvedValue({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '2',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await controller.onPopupOpened({ creativeId: '42' })

		expect(controller.currentTopicId).toBe('3')
		resolveBetaSave(true)
		await betaSave
	})

	test('a picked value keeps its in-flight snapshot as the baseline for a later closed save', async () => {
		let resolveInitialSnapshot
		let resolveSave
		global.fetch = jest.fn(() => new Promise((resolve) => { resolveInitialSnapshot = resolve }))

		const initialLoad = controller.loadTopics()
		controller.selectTopic('2')
		resolveInitialSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await initialLoad

		expect(controller.currentTopicId).toBe('2')
		expect(controller.lastKnownRemoteTopicId).toBe('1')

		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		controller.onPopupClosed()
		global.fetch = jest.fn().mockResolvedValue({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await controller.onPopupOpened({ creativeId: '42' })

		expect(controller.currentTopicId).toBe('2')
		resolveSave(true)
		await save
	})

	test('a new creative records its own snapshot baseline before its first save', async () => {
		let resolveSnapshot
		controller.lastKnownRemoteTopicId = '3'
		controller.creativeIdValue = '99'
		controller._renderedCreativeId = '99'
		global.fetch = jest.fn(() => new Promise((resolve) => { resolveSnapshot = resolve }))

		const load = controller.loadTopics()
		controller.selectTopic('2')
		resolveSnapshot({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				main_topic_id: '1',
				effective_creative_id: '99',
			}),
		})
		await load

		expect(controller.lastKnownRemoteTopicId).toBe('1')
		await controller.flushSaveLastTopic('2')
		expect(controller.pendingSelfEchoPreviousTopicIds.get(clientIdFor('2'))).toBe('1')
	})

	test('a queued save uses its preceding save as the stream baseline after another creative loads', async () => {
		let resolveFirstSave
		let resolveSecondSave
		controller.lastKnownRemoteTopicId = '1'
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveFirstSave = resolve }))
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSecondSave = resolve }))

		const firstSave = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		const queuedSave = controller.flushSaveLastTopic('3')

		global.fetch = jest.fn().mockResolvedValue({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '3',
				main_topic_id: '1',
				effective_creative_id: '99',
			}),
		})
		await controller.onPopupOpened({ creativeId: '99' })

		resolveFirstSave(true)
		await firstSave
		await Promise.resolve()

		expect(controller.pendingSelfEchoPreviousTopicIds.get(clientIdFor('3'))).toBe('2')
		resolveSecondSave(true)
		await queuedSave
	})

	test('a temporary creative switch keeps an in-flight save claim for its returning stream', async () => {
		let resolveSave
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		const clientId = clientIdFor('2')

		global.fetch = jest.fn()
			.mockResolvedValueOnce({
				ok: true,
				json: async () => ({
					topics: TOPICS,
					archived_topics: [],
					can_manage: true,
					last_topic_id: '1',
					main_topic_id: '1',
					effective_creative_id: '99',
				}),
			})
			.mockResolvedValueOnce({
				ok: true,
				json: async () => ({
					topics: TOPICS,
					archived_topics: [],
					can_manage: true,
					last_topic_id: '1',
					main_topic_id: '1',
					effective_creative_id: '42',
				}),
			})

		await controller.onPopupOpened({ creativeId: '99' })
		await controller.onPopupOpened({ creativeId: '42' })
		controller.selectTopic('3')

		selfEcho('2')

		expect(controller.pendingSelfEchoes).not.toContain(clientId)
		expect(controller.currentTopicId).toBe('3')
		resolveSave(true)
		await save
	})

  test('a reopen keeps a newer server preference after a closed save completed', async () => {
    let resolveSave
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
    controller.selectTopic('2')
    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()

    controller.onPopupClosed()
    resolveSave(true)
    await save

    expect(controller.pendingSelfEchoes).toEqual([])
    global.fetch = jest.fn().mockResolvedValue({
		ok: true,
		json: async () => ({
			topics: TOPICS,
			archived_topics: [],
			can_manage: true,
			last_topic_id: '3',
			main_topic_id: '1',
			effective_creative_id: '42',
		}),
	})
    await controller.onPopupOpened({ creativeId: '42' })

    expect(controller.currentTopicId).toBe('3')
  })

  test('a reopened snapshot newer than a closed in-flight save is not overwritten', async () => {
    let resolveSave
    controller.lastKnownRemoteTopicId = '1'
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
    controller.selectTopic('2')
    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()

    controller.onPopupClosed()
    global.fetch = jest.fn().mockResolvedValue({
		ok: true,
		json: async () => ({
			topics: TOPICS,
			archived_topics: [],
			can_manage: true,
			last_topic_id: '3',
			main_topic_id: '1',
			effective_creative_id: '42',
		}),
    })
    await controller.onPopupOpened({ creativeId: '42' })

    expect(controller.currentTopicId).toBe('3')
    resolveSave(true)
    await save
    expect(controller.pendingSelfEchoes).toHaveLength(1)
  })

  test('a queued save claimed after closing yields to a newer reopen snapshot', async () => {
    let resolveFirst
    let resolveSecond
    controller.lastKnownRemoteTopicId = '1'
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve }))
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSecond = resolve }))

    controller.selectTopic('2')
    const first = controller.flushSaveLastTopic('2')
    await Promise.resolve()
    controller.selectTopic('3')
    const second = controller.flushSaveLastTopic('3')

    controller.onPopupClosed()
    resolveFirst(true)
    await first
    await Promise.resolve()

    const queuedClientId = clientIdFor('3')
    expect(controller.possiblyMissedPendingSelfEchoes).toContain(queuedClientId)

    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
		topics: TOPICS,
		archived_topics: [],
		can_manage: true,
		last_topic_id: '1',
		main_topic_id: '1',
		effective_creative_id: '42',
      }),
    })
    await controller.onPopupOpened({ creativeId: '42' })

    expect(controller.currentTopicId).toBe('1')
    resolveSecond(true)
    await second
  })

  test('a response after reopening keeps its claim until the delayed echo lands', async () => {
    let resolveSave
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
    controller.selectTopic('2')
    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()

    controller.onPopupClosed()
    controller.loadTopics = jest.fn()
    controller.onPopupOpened({ creativeId: '42' })
    controller.selectTopic('3')

    resolveSave(true)
    await save
    expect(controller.pendingSelfEchoes).toHaveLength(1)

    selfEcho('2')
    expect(controller.currentTopicId).toBe('3')
  })

	test('a closed later save keeps the previous locally committed preference', async () => {
		controller.lastKnownRemoteTopicId = '1'
		controller.selectTopic('2')
		await controller.flushSaveLastTopic('2')
		expect(controller.lastKnownRemoteTopicId).toBe('2')
		selfEcho('2')

		let resolveSave
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
		controller.selectTopic('3')
		const save = controller.flushSaveLastTopic('3')
		await Promise.resolve()

		controller.onPopupClosed()
		global.fetch = jest.fn().mockResolvedValue({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '2',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await controller.onPopupOpened({ creativeId: '42' })

		expect(controller.currentTopicId).toBe('3')
		resolveSave(true)
		await save
	})

  test('reopening an origin after its linked shell keeps the shared stream claim', async () => {
    controller.creativeIdValue = '77'
    controller.element.dataset.effectiveCreativeId = '42'
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.onPopupClosed()
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        topics: TOPICS,
        archived_topics: [],
        can_manage: true,
        last_topic_id: '2',
        main_topic_id: '1',
        effective_creative_id: '42',
      }),
    })
    await controller.onPopupOpened({ creativeId: '42' })
    controller.selectTopic('3')
    selfEcho('2')

    expect(controller.currentTopicId).toBe('3')
  })

	test('direct navigation from a linked shell to its origin keeps the shared stream claim', async () => {
		controller.creativeIdValue = '77'
		controller.element.dataset.effectiveCreativeId = '42'
		controller.subscribe()
		controller.selectTopic('2')
		await controller.flushSaveLastTopic('2')

		global.fetch = jest.fn().mockResolvedValue({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '2',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await controller.onPopupOpened({ creativeId: '42' })
		controller.selectTopic('3')
		selfEcho('2')

		expect(controller.currentTopicId).toBe('3')
	})

  test('reopening the same linked shell keeps its origin stream claim', async () => {
    controller.creativeIdValue = '77'
    controller.element.dataset.effectiveCreativeId = '42'
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.onPopupClosed()
	global.fetch = jest.fn().mockResolvedValue({
		ok: true,
		json: async () => ({
			topics: TOPICS,
			archived_topics: [],
			can_manage: true,
			last_topic_id: '2',
			main_topic_id: '1',
			effective_creative_id: '42',
		}),
	})
    await controller.onPopupOpened({ creativeId: '77' })
    controller.selectTopic('3')
    selfEcho('2')

    expect(controller.currentTopicId).toBe('3')
  })

	test('a reopened linked shell keeps an in-flight claim before its replacement load resolves', async () => {
		controller.creativeIdValue = '77'
		global.fetch = jest.fn().mockResolvedValueOnce({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '1',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await controller.loadTopics()

		let resolveSave
		let resolveReopen
		saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
		controller.selectTopic('2')
		const save = controller.flushSaveLastTopic('2')
		await Promise.resolve()
		const alphaClientId = clientIdFor('2')

		controller.onPopupClosed()
		global.fetch.mockImplementationOnce(() => new Promise((resolve) => { resolveReopen = resolve }))
		const reopen = controller.onPopupOpened({ creativeId: '77' })
		await Promise.resolve()

		resolveSave(true)
		await save
		expect(controller.pendingSelfEchoes).toContain(alphaClientId)

		resolveReopen({
			ok: true,
			json: async () => ({
				topics: TOPICS,
				archived_topics: [],
				can_manage: true,
				last_topic_id: '2',
				main_topic_id: '1',
				effective_creative_id: '42',
			}),
		})
		await reopen

		controller.selectTopic('3')
		selfEcho('2')

		expect(controller.currentTopicId).toBe('3')
	})

  test('a pre-resolution linked-shell save keeps its claim after resolving its origin', async () => {
    controller.creativeIdValue = '77'
    delete controller.element.dataset.effectiveCreativeId
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
	topics: TOPICS,
	archived_topics: [],
	can_manage: true,
	last_topic_id: '2',
	main_topic_id: '1',
	effective_creative_id: '42',
      }),
    })
    await controller.loadTopics()

    expect(controller.pendingSelfEchoCreativeIds.get(clientIdFor('2'))).toBe('42')
    controller.selectTopic('3')
    selfEcho('2')

    expect(controller.currentTopicId).toBe('3')
  })

  test('a debounced linked-shell save retains its resolved stream after close and sibling reopen', async () => {
    let resolveSave
    jest.useFakeTimers()
    try {
      controller.creativeIdValue = '77'
      controller.element.dataset.effectiveCreativeId = '42'
      saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))

      controller.selectTopic('2')
      controller.onPopupClosed()
      controller.loadTopics = jest.fn()
      controller.onPopupOpened({ creativeId: '88' })
      await jest.advanceTimersByTimeAsync(500)

      const oldSaveClientId = clientIdFor('2')
      expect(controller.pendingSelfEchoCreativeIds.get(oldSaveClientId)).toBe('42')

      controller.selectTopic('3')
      echo('2', oldSaveClientId)

      expect(controller.currentTopicId).toBe('3')
      resolveSave(true)
    } finally {
      jest.useRealTimers()
    }
  })

  test('a legacy migration echo is correlated with a later pick', async () => {
    localStorage.setItem('collavre_creative_42_last_topic', '2')
    controller.serverLastTopicId = ''

    controller.migrateLocalStorage()
    await Promise.resolve()
    await Promise.resolve()
    const migrationClientId = clientIdFor('2')
    expect(migrationClientId).toEqual(expect.any(String))

    controller.selectTopic('3')
    echo('2', migrationClientId)

    expect(controller.currentTopicId).toBe('3')
  })

  test('reopening a different creative retains claims from the one left', async () => {
    controller.selectTopic('2')
    await controller.flushSaveLastTopic('2')

    controller.onPopupClosed()
    global.fetch = jest.fn().mockResolvedValue({
		ok: true,
		json: async () => ({
			topics: TOPICS,
			archived_topics: [],
			can_manage: true,
			last_topic_id: '1',
			main_topic_id: '1',
			effective_creative_id: '99',
		}),
	})
    await controller.onPopupOpened({ creativeId: '99' })

    expect(controller.pendingSelfEchoes).toHaveLength(1)
  })

  test('a completed save releases its claim after navigation subscribes to another stream', async () => {
    let resolveSave
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve }))
    global.fetch = jest.fn().mockResolvedValue({
		ok: true,
		json: async () => ({
			topics: TOPICS,
			archived_topics: [],
			can_manage: true,
			last_topic_id: '',
			main_topic_id: '1',
			effective_creative_id: '99',
		}),
	})

    const save = controller.flushSaveLastTopic('2')
    await Promise.resolve()
    const alphaClientId = clientIdFor('2')

    const openDifferentCreative = controller.onPopupOpened({ creativeId: '99' })
    resolveSave(true)
    await Promise.all([save, openDifferentCreative])

    expect(controller.pendingSelfEchoes).not.toContain(alphaClientId)
    expect(controller.pendingSelfEchoCreativeIds.has(alphaClientId)).toBe(false)
  })

  // unsubscribe() is the deliberate exit, and a refused subscription cannot
  // reconnect, so both discard their claims. A dropped connection is different:
  // its in-flight request can still broadcast after ActionCable reconnects.
  describe('claims against a subscription that goes away on its own', () => {
    // Delivered the way the real ones are, through the subscription itself.
    const deliver = (lastTopicId, clientId) => subscriptionCallbacks.received({
      action: 'last_topic_changed',
      last_topic_id: lastTopicId,
      ...(clientId === undefined ? {} : { client_id: clientId }),
    })

    beforeEach(() => {
      subscriptionCallbacks = undefined
      controller.subscribe()
    })

    // The consumer reconnects by itself and the subscription comes back, so
    // the controller registers nothing for the gap — claims stay exactly where
    // they were. Asserting the absence is the point: a handler here would be
    // discarding claims that can still be settled.
    const dropAndReconnect = () => {
      expect(subscriptionCallbacks.disconnected).toBeUndefined()
    }

    test('a reconnectable disconnect keeps an in-flight claim for its delayed echo', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      dropAndReconnect()

      expect(controller.pendingSelfEchoes).toEqual([clientIdFor('2')])
      // Reconnected, and the user has since picked Beta. The delayed echo of
      // the request made before the reconnect is still ours, not new state.
      controller.selectTopic('3')
      deliver('2', clientIdFor('2'))
      expect(controller.currentTopicId).toBe('3')
    })

    test('a real update still applies after a reconnectable disconnect', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      dropAndReconnect()

      // Reconnected, and another session moves the preference to Alpha.
      controller.selectTopic('3')
      deliver('2')
      expect(controller.currentTopicId).toBe('2')
    })

    // The same reasoning one step along the queue. A save waiting its turn is
    // sent after the consumer has reconnected, so its echo is not lost at all
    // — refusing it a claim on the strength of the disconnect would let its
    // own echo revert whatever the user picked while it was queued.
    test('a save queued across a reconnect still claims its echo', async () => {
      let resolveFirst
      saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve }))
      const first = controller.flushSaveLastTopic('2')
      const second = controller.flushSaveLastTopic('3')
      await Promise.resolve()

      dropAndReconnect()
      resolveFirst(true)
      await Promise.all([first, second])

      controller.selectTopic('')
      deliver('3', clientIdFor('3'))

      expect(controller.currentTopicId).toBe('')
    })

    test('a refused subscription drops outstanding claims', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      subscriptionCallbacks.rejected()

      expect(controller.pendingSelfEchoes).toHaveLength(0)
      controller.selectTopic('3')
      deliver('2')
      expect(controller.currentTopicId).toBe('2')
    })

    test('a refused different-creative subscription retains the original stream claim', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')
      const alphaClientId = clientIdFor('2')

      controller.creativeIdValue = '99'
      controller.subscribe({ preservePendingSelfEchoes: true })
      subscriptionCallbacks.rejected()

      expect(controller.pendingSelfEchoes).toContain(alphaClientId)
      controller.creativeIdValue = '42'
      controller.subscribe({ preservePendingSelfEchoes: true })
      controller.selectTopic('3')
      deliver('2', alphaClientId)

      expect(controller.currentTopicId).toBe('3')
    })

    // The claim is only dropped by those two — an ordinary echo on a healthy
    // subscription still settles the save that is waiting for it.
    test('an echo on a live subscription is still consumed', async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      controller.selectTopic('3')
      deliver('2', clientIdFor('2'))

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
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '2', expect.any(String))

      resolveFirst(true)
      await Promise.all(pending)

      expect(saveLastTopic).toHaveBeenCalledTimes(2)
      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3', expect.any(String))
    })

    // With the sends ordered, the echoes are too: the first save's broadcast is
    // emitted before the second save is even sent. Both are then claimed and
    // consumed in turn, and nothing is left to swallow a later update.
    test('leaves no claim behind once both echoes land', async () => {
      const pending = await startTwoSaves()
      selfEcho('2')
      resolveFirst(true)
      await Promise.all(pending)
      selfEcho('3')

      // The user moves on, and another session picks Beta for real.
      controller.selectTopic('')
      echo('3')

      expect(controller.currentTopicId).toBe('3')
    })

    // An ambiguous delivery still has to hand the queue on, or every later
    // pick is stranded behind it. It keeps its claim, though: the server can
    // have accepted the PATCH and broadcast after fetch reports a failure.
    test('an ambiguous save does not strand the one behind it', async () => {
      let rejectFirst
      saveLastTopic.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectFirst = reject }))
      controller.selectTopic('2')
      const first = controller.flushSaveLastTopic('2')
      controller.selectTopic('3')
      const second = controller.flushSaveLastTopic('3')
      await Promise.resolve()

      rejectFirst(new Error('network'))
      await Promise.all([first, second])

      expect(saveLastTopic).toHaveBeenLastCalledWith('42', '3', expect.any(String))
      controller.selectTopic('')
      selfEcho('2')
      expect(controller.currentTopicId).toBe('')
    })
  })

  // Topic equality is not sender identity. Two sessions of the same user can
  // save the same topic at the same time, and their broadcasts are then
  // indistinguishable by payload — so one claim gets settled by the wrong
  // message and the client's own echo comes back looking like news.
  describe('another session that named the same topic', () => {
    const raceOnAlpha = async () => {
      controller.selectTopic('2')
      await controller.flushSaveLastTopic('2')

      // The other session had moved the preference to Alpha too, and its
      // broadcast is the first of the two to arrive.
      echo('2')
      // Ours has still not landed when the user picks Beta.
      controller.selectTopic('3')
      selfEcho('2')
    }

    test('its broadcast does not settle a claim of ours', async () => {
      await raceOnAlpha()

      expect(controller.currentTopicId).toBe('3')
      expect(changeEvents.at(-1).topicId).toBe('3')
    })

    test('our own late echo is not recorded over the newer pick', async () => {
      await raceOnAlpha()

      expect(controller.serverLastTopicId).toBe('3')
    })
  })

  // crypto.randomUUID is only defined in a secure context, and the app is
  // reachable over plain http — so the fallback is a live path, not a
  // formality, and an id from it has to be just as unguessable by a sibling
  // tab as a uuid is.
  test('ids are still unique per save without crypto.randomUUID', async () => {
    Object.defineProperty(global.crypto, 'randomUUID', { value: undefined, configurable: true })

    try {
      await controller.flushSaveLastTopic('2')
      await controller.flushSaveLastTopic('3')
    } finally {
      delete global.crypto.randomUUID
    }

    const ids = saveLastTopic.mock.calls.map(c => c[2])
    expect(ids).toHaveLength(2)
    ids.forEach(id => expect(id).toMatch(/^save-/))
    expect(new Set(ids).size).toBe(2)
  })

  // Claims are taken inside the queued callback, which runs whenever the save
  // ahead of it finishes — by then the subscription that would settle the claim
  // may already be gone, and clearing the queue at that moment cannot reach a
  // claim that does not exist yet.
  test('a save queued behind another leaves no claim once the stream is gone', async () => {
    let resolveFirst
    saveLastTopic.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve }))
    const first = controller.flushSaveLastTopic('2')
    const second = controller.flushSaveLastTopic('3')
    await Promise.resolve()

    controller.unsubscribe()
    resolveFirst(true)
    await Promise.all([first, second])

    expect(controller.pendingSelfEchoes).toHaveLength(0)
  })
})
