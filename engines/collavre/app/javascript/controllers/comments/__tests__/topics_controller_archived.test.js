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
})
