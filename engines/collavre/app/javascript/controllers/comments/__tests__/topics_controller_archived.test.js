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

const TOPICS = [{ id: 1, name: 'Main' }, { id: 2, name: 'Alpha' }]
const ARCHIVED = [{ id: 3, name: 'Zeta' }, { id: 4, name: 'Omega' }]

describe('TopicsController archived topic messages', () => {
  let application
  let controller
  let changeEvents

  const render = () => controller.renderTopics(controller.topics, controller.canManageTopics)

  // Stimulus binds actions on freshly inserted nodes via a MutationObserver, so
  // a click dispatched in the same tick as the render would hit nothing.
  const renderAndBind = async () => {
    render()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="topics" data-controller="comments--topics" data-topic-main-text="All Messages">
        <div data-comments--topics-target="list"></div>
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
      controller = application.getControllerForElementAndIdentifier(
        document.getElementById('topics'), 'comments--topics'
      )
      controller.creativeIdValue = '42'
      controller.topics = TOPICS
      controller.archivedTopics = ARCHIVED
      controller.mainTopicId = '1'
      controller.canManageTopics = true
      controller.showingArchived = false
      controller.serverLastTopicId = ''
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    application.stop()
    jest.clearAllMocks()
  })

  describe('selecting an archived topic', () => {
    test('archived chips carry the select action so clicking one opens it', () => {
      controller.showingArchived = true
      render()

      const chip = controller.listTarget.querySelector('.topic-archived[data-id="3"]')
      expect(chip.dataset.action).toContain('click->comments--topics#select')
    })

    test('clicking an archived chip dispatches change with its topic id', async () => {
      controller.showingArchived = true
      await renderAndBind()

      controller.listTarget.querySelector('.topic-archived[data-id="3"]').click()

      expect(changeEvents.at(-1).topicId).toBe('3')
    })

    test('the selected archived chip renders as active', () => {
      controller.showingArchived = true
      controller.serverLastTopicId = '3'
      render()

      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]').classList)
        .toContain('active')
    })

    test('clicking Restore unarchives without also selecting the topic', async () => {
      const fetchMock = jest.fn().mockResolvedValue({ ok: true })
      global.fetch = fetchMock
      controller.loadTopics = jest.fn()
      controller.showingArchived = true
      await renderAndBind()

      controller.listTarget.querySelector('.unarchive-topic-btn[data-id="3"]').click()

      expect(fetchMock).toHaveBeenCalledWith(
        '/creatives/42/topics/3/unarchive',
        expect.objectContaining({ method: 'PATCH' })
      )
      expect(changeEvents).toHaveLength(0)
    })
  })

  describe('restoreSelection', () => {
    test('keeps an archived topic selected instead of falling back to Main', () => {
      controller.serverLastTopicId = '3'
      render()

      controller.restoreSelection()

      expect(changeEvents.at(-1).topicId).toBe('3')
    })

    test('expands the archived section so the selected topic is visible', () => {
      controller.serverLastTopicId = '3'
      render()
      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).toBeNull()

      controller.restoreSelection()

      expect(controller.showingArchived).toBe(true)
      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).not.toBeNull()
    })

    test('keeps a live topic selected without expanding the archived section', () => {
      controller.serverLastTopicId = '2'
      render()

      controller.restoreSelection()

      expect(changeEvents.at(-1).topicId).toBe('2')
      expect(controller.showingArchived).toBe(false)
    })

    test('falls back to Main for a topic id that no longer exists', () => {
      controller.serverLastTopicId = '999'
      render()

      controller.restoreSelection()

      expect(changeEvents.at(-1).topicId).toBe('1')
    })

    test('falls back to Main when there are no archived topics at all', () => {
      controller.archivedTopics = []
      controller.serverLastTopicId = '3'
      render()

      controller.restoreSelection()

      expect(changeEvents.at(-1).topicId).toBe('1')
    })
  })

  describe('revealing the archived section', () => {
    test('selecting an archived topic from the topic-list popup expands the section', () => {
      render()
      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).toBeNull()

      // What openTopicListPopup hands the popup as its pick callback.
      controller.selectTopic('3')

      expect(controller.showingArchived).toBe(true)
      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]').classList)
        .toContain('active')
    })

    test('selecting a live topic leaves the archived section collapsed', () => {
      render()

      controller.selectTopic('2')

      expect(controller.showingArchived).toBe(false)
    })

    test('collapsing the section stays collapsed while an archived topic is open', () => {
      controller.serverLastTopicId = '3'
      controller.showingArchived = true
      render()

      controller.toggleArchivedTopics({ stopPropagation: jest.fn() })

      expect(controller.showingArchived).toBe(false)
      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).toBeNull()
    })

    test('toggling the section does not reload the message list', () => {
      controller.showingArchived = true
      render()

      controller.toggleArchivedTopics({ stopPropagation: jest.fn() })

      expect(changeEvents).toHaveLength(0)
    })

    describe('after the user collapses the section on the topic they are in', () => {
      const collapse = () => controller.toggleArchivedTopics({ stopPropagation: jest.fn() })
      const rename = () => controller.updateTopicInList({ id: 2, name: 'Alpha renamed' })

      beforeEach(() => {
        controller.serverLastTopicId = '3'
        controller.showingArchived = true
        render()
        collapse()
      })

      test('an unrelated rename does not reopen it', () => {
        rename()

        expect(controller.showingArchived).toBe(false)
        expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).toBeNull()
      })

      test('a reorder does not reopen it', () => {
        controller.reorderTopicsFromServer([2, 1])

        expect(controller.showingArchived).toBe(false)
      })

      test('the hidden topic stays selected', () => {
        rename()

        expect(String(controller.currentTopicId)).toBe('3')
      })

      test('deliberately reselecting the topic reopens the section', () => {
        controller.selectTopic('3')

        expect(controller.showingArchived).toBe(true)
        expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]').classList)
          .toContain('active')
      })

      test('a rename after that reselection leaves the section open', () => {
        controller.selectTopic('3')

        rename()

        expect(controller.showingArchived).toBe(true)
      })

      test('re-expanding by hand also drops the suppression', () => {
        collapse()

        rename()

        expect(controller.showingArchived).toBe(true)
      })
    })

    test('collapsing while a live topic is open still reveals a restored archived one', () => {
      controller.serverLastTopicId = '2'
      controller.showingArchived = true
      render()

      controller.toggleArchivedTopics({ stopPropagation: jest.fn() })
      controller.serverLastTopicId = '3'
      controller.restoreSelection()

      expect(controller.showingArchived).toBe(true)
    })
  })

  describe('new message badges', () => {
    const newMessage = (topicId) => controller.handleNewMessage({ detail: { topicId } })

    test('badges the archived toggle when the section is collapsed', () => {
      render()

      newMessage('3')

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test('badges both the chip and the toggle when the section is expanded', () => {
      controller.showingArchived = true
      render()

      newMessage('3')

      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]').classList)
        .toContain('has-new-messages')
      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test('the toggle badge survives a re-render', () => {
      render()
      newMessage('3')

      render()

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test('a live topic does not badge the archived toggle', () => {
      render()

      newMessage('2')

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .not.toContain('has-new-messages')
    })

    test('the toggle badge stays while another archived topic is still unread', () => {
      render()
      newMessage('3')
      newMessage('4')

      controller.selectTopic('3')

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test('the toggle badge clears once every archived topic has been read', () => {
      render()
      newMessage('3')
      newMessage('4')

      controller.selectTopic('3')
      controller.selectTopic('4')

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .not.toContain('has-new-messages')
    })

    test('ignores a message for the topic already being viewed', () => {
      controller.serverLastTopicId = '3'
      render()

      newMessage('3')

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .not.toContain('has-new-messages')
    })
  })

  // The toggle badge is derived from the unread set's size, so any id left in it
  // that no longer belongs to an archived topic lights the toggle with no chip
  // to click and clear it.
  describe('stale unread state', () => {
    const newMessage = (topicId) => controller.handleNewMessage({ detail: { topicId } })

    // popup_controller._navigateToEntry reuses open()/openForCreative() on this
    // same instance, so no onPopupClosed runs between two creatives.
    const switchCreative = async (creativeId) => {
      controller.subscribe = jest.fn()
      controller.loadTopics = jest.fn().mockResolvedValue(undefined)
      await controller.onPopupOpened({ creativeId })
    }

    test('switching creatives drops the previous creative unread marks', async () => {
      render()
      newMessage('3')
      expect(controller.archivedWithNewMessages.size).toBe(1)

      await switchCreative('99')

      expect(controller.archivedWithNewMessages.size).toBe(0)
    })

    // popup_controller.handleCreativeClick re-opens the *same* creative when a
    // docked chat receives a workspace-sync event carrying a highlightId. These
    // marks are transient — loadTopics() cannot rebuild them — so following a
    // comment deep link must not wipe the other archived topics' unread state.
    test('re-opening the same creative keeps its unread marks', async () => {
      render()
      newMessage('3')
      newMessage('4')

      await switchCreative('42')

      expect([...controller.archivedWithNewMessages].sort()).toEqual(['3', '4'])
    })

    test('the toggle stays badged after re-opening the same creative', async () => {
      render()
      newMessage('3')

      await switchCreative('42')
      render()

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test("the new creative's archived toggle renders unbadged after a switch", async () => {
      render()
      newMessage('3')

      await switchCreative('99')
      controller.topics = [{ id: 10, name: 'Main' }]
      controller.archivedTopics = [{ id: 11, name: 'Other' }]
      render()

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .not.toContain('has-new-messages')
    })

    test('loadTopics drops unread marks for topics that are no longer archived', async () => {
      render()
      newMessage('3')
      newMessage('4')

      // Topic 3 was restored to the live strip; only 4 is still archived.
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          topics: [{ id: 1, name: 'Main' }, { id: 3, name: 'Zeta' }],
          archived_topics: [{ id: 4, name: 'Omega' }],
          can_manage: true,
          main_topic_id: 1,
        }),
      })

      await controller.loadTopics()

      expect([...controller.archivedWithNewMessages]).toEqual(['4'])
      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test('the toggle badge clears when the only unread topic is unarchived', () => {
      render()
      newMessage('3')

      controller.archivedTopics = [{ id: 4, name: 'Omega' }]
      controller.pruneArchivedBadges()
      render()

      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .not.toContain('has-new-messages')
    })
  })

  // Archiving the topic in view switches to All Messages, but the preference
  // save is debounced 500ms — so the topics reload it triggers (and the one the
  // "archived" broadcast triggers) still reads the archived topic as
  // last_topic_id. restoreSelection accepts archived ids now, so nothing else
  // stops it from putting the user back where they just left.
  describe('archiving the topic in view', () => {
    // Route by URL: the archive PATCH and the topics reload both go through
    // the same global fetch. lastTopicId is what the server preference still
    // reports at reload time.
    const stubFetch = (lastTopicId) => {
      global.fetch = jest.fn((url) => {
        if (String(url).includes('/archive')) return Promise.resolve({ ok: true })
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({
            topics: [{ id: 1, name: 'Main' }],
            archived_topics: [{ id: 2, name: 'Alpha' }, ...ARCHIVED],
            can_manage: true,
            main_topic_id: 1,
            last_topic_id: lastTopicId,
          }),
        })
      })
    }

    // archiveTopic fires loadTopics without awaiting it.
    const archive = async (topicId) => {
      await controller.archiveTopic({
        stopPropagation: jest.fn(),
        currentTarget: { dataset: { id: topicId } },
      })
      await new Promise((resolve) => setTimeout(resolve, 0))
    }

    test('does not reselect the topic the reload still reports as last_topic_id', async () => {
      controller.serverLastTopicId = '2'
      render()
      stubFetch(2)

      await archive('2')

      expect(changeEvents.at(-1).topicId).toBe('1')
      expect(controller.currentTopicId).toBe('1')
    })

    test('leaves the archived section collapsed instead of revealing the archived topic', async () => {
      controller.serverLastTopicId = '2'
      render()
      stubFetch(2)

      await archive('2')

      expect(controller.showingArchived).toBe(false)
      expect(controller.listTarget.querySelector('.topic-archived[data-id="2"]')).toBeNull()
    })

    test('a deep-link override does not keep reporting the archived topic as current', async () => {
      controller.setOverrideTopicId('2')
      render()
      stubFetch(2)

      await archive('2')

      expect(controller.overrideTopicId).toBeUndefined()
      expect(controller.currentTopicId).toBe('1')
    })

    test('the user can still go back into the topic they just archived', async () => {
      controller.serverLastTopicId = '2'
      render()
      stubFetch(2)
      await archive('2')

      controller.selectTopic('2')
      controller.restoreSelection()

      expect(changeEvents.at(-1).topicId).toBe('2')
      expect(controller.showingArchived).toBe(true)
    })

    test('the guard lifts once the server preference stops naming the topic', async () => {
      controller.serverLastTopicId = '2'
      render()
      stubFetch(2)
      await archive('2')

      stubFetch(null)
      await controller.loadTopics()
      // Reselected elsewhere — another tab, or a deep link.
      stubFetch(2)
      await controller.loadTopics()

      expect(changeEvents.at(-1).topicId).toBe('2')
    })

    // ?topic_id= outranks the saved preference in the currentTopicId getter and
    // survives every reload, so it has to be cleared too — otherwise the guard
    // is the only thing holding the selection back, and it lifts the moment the
    // preference save lands.
    describe('when the URL names the archived topic', () => {
      beforeEach(() => {
        window.history.replaceState({}, '', '/?topic_id=2')
      })

      afterEach(() => {
        window.history.replaceState({}, '', '/')
      })

      test('drops the query parameter', async () => {
        render()
        stubFetch(2)

        await archive('2')

        expect(new URLSearchParams(window.location.search).get('topic_id')).toBeNull()
        expect(controller.currentTopicId).toBe('1')
      })

      test('a later reload does not put the user back into it', async () => {
        render()
        stubFetch(2)
        await archive('2')

        // The preference save has landed by now, so the guard's old lift
        // condition would fire here.
        stubFetch(null)
        await controller.loadTopics()

        expect(changeEvents.at(-1).topicId).toBe('1')
        expect(controller.showingArchived).toBe(false)
      })

      test('leaves a query parameter naming a different topic alone', async () => {
        controller.topics = [...TOPICS, { id: 5, name: 'Beta' }]
        render()
        stubFetch(2)

        await archive('5')

        expect(new URLSearchParams(window.location.search).get('topic_id')).toBe('2')
      })
    })

    test('archiving a topic that is not in view leaves the selection alone', async () => {
      controller.topics = [...TOPICS, { id: 5, name: 'Beta' }]
      controller.serverLastTopicId = '2'
      render()
      global.fetch = jest.fn((url) => {
        if (String(url).includes('/archive')) return Promise.resolve({ ok: true })
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({
            topics: TOPICS,
            archived_topics: [{ id: 5, name: 'Beta' }, ...ARCHIVED],
            can_manage: true,
            main_topic_id: 1,
            last_topic_id: 2,
          }),
        })
      })

      await archive('5')

      expect(changeEvents.at(-1).topicId).toBe('2')
    })
  })

  // The "deleted" broadcast is the one removal path that runs without a
  // loadTopics(), so it is the only thing that can prune the archived cache
  // when an admin deletes an archived topic from another client or the API.
  describe('a deleted broadcast for an archived topic', () => {
    const deleteBroadcast = (topicId) =>
      controller.handleTopicMessage({ action: 'deleted', topic_id: topicId })

    test('drops it from the archived cache', () => {
      deleteBroadcast(3)

      expect(controller.archivedTopics.map((t) => t.id)).toEqual([4])
    })

    test('removes its chip so it can no longer be opened', () => {
      controller.showingArchived = true
      render()
      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).not.toBeNull()

      deleteBroadcast(3)

      expect(controller.listTarget.querySelector('.topic-archived[data-id="3"]')).toBeNull()
      expect(controller.listTarget.querySelector('.topic-archived[data-id="4"]')).not.toBeNull()
    })

    test('moves the viewer out of it instead of leaving them on a dead conversation', () => {
      controller.serverLastTopicId = '3'

      deleteBroadcast(3)

      expect(changeEvents.at(-1).topicId).toBe('1')
      expect(controller.serverLastTopicId).toBe('1')
    })

    test('clears the toggle badge it was holding', () => {
      render()
      controller.handleNewMessage({ detail: { topicId: '3' } })
      expect(controller.archivedWithNewMessages.has('3')).toBe(true)
      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')

      deleteBroadcast(3)

      expect(controller.archivedWithNewMessages.has('3')).toBe(false)
      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .not.toContain('has-new-messages')
    })

    // Another archived topic still unread keeps the toggle lit — the badge
    // aggregates the whole section.
    test('leaves the toggle lit when another archived topic is still unread', () => {
      render()
      controller.handleNewMessage({ detail: { topicId: '3' } })
      controller.handleNewMessage({ detail: { topicId: '4' } })

      deleteBroadcast(3)

      expect([...controller.archivedWithNewMessages]).toEqual(['4'])
      expect(controller.listTarget.querySelector('.topic-archived-toggle').classList)
        .toContain('has-new-messages')
    })

    test('still removes a live topic', () => {
      deleteBroadcast(2)

      expect(controller.topics.map((t) => t.id)).toEqual([1])
      expect(controller.archivedTopics.map((t) => t.id)).toEqual([3, 4])
    })

    test('does nothing for an id in neither list', () => {
      deleteBroadcast(99)

      expect(controller.topics.map((t) => t.id)).toEqual([1, 2])
      expect(controller.archivedTopics.map((t) => t.id)).toEqual([3, 4])
      expect(changeEvents).toEqual([])
    })

    // Assigning "" only moves the preference, and both deep-link sources outrank
    // it in the currentTopicId getter, so the deleted id would keep answering
    // for every later restoreSelection().
    describe('while a deep link still names it', () => {
      test('clears an overrideTopicId pointing at it', () => {
        controller.setOverrideTopicId('3')

        deleteBroadcast(3)

        expect(controller.currentTopicId).toBe('1')
      })

      test('drops a ?topic_id= naming it', () => {
        window.history.replaceState({}, '', '/?topic_id=3')

        deleteBroadcast(3)

        expect(new URLSearchParams(window.location.search).get('topic_id')).toBeNull()
        expect(controller.currentTopicId).toBe('1')

        window.history.replaceState({}, '', '/')
      })

      // The point of clearing them: a re-render must not throw away the topic
      // the user picked after the deletion.
      test('a later re-render keeps the topic the user chose instead', () => {
        controller.setOverrideTopicId('3')
        deleteBroadcast(3)

        controller.selectTopic('2')
        controller.renderTopics(controller.topics, controller.canManageTopics)
        controller.restoreSelection()

        expect(controller.currentTopicId).toBe('2')
        expect(changeEvents.at(-1).topicId).toBe('2')
      })

      test('leaves a deep link pointing at a different topic alone', () => {
        window.history.replaceState({}, '', '/?topic_id=4')

        deleteBroadcast(3)

        expect(new URLSearchParams(window.location.search).get('topic_id')).toBe('4')

        window.history.replaceState({}, '', '/')
      })
    })
  })
})
