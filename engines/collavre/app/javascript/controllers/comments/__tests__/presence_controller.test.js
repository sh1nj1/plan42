/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import PresenceController from '../presence_controller'

describe('CommentsPresenceController', () => {
  let application
  let container
  let controller

  beforeEach(async () => {
    document.body.dataset.currentUserId = '7'
    global.fetch = jest.fn()

    container = document.createElement('div')
    container.innerHTML = `
      <div id="comments-popup"
           data-controller="comments--presence"
           data-no-permission-text="No permission">
        <div data-comments--presence-target="participants"></div>
        <div data-comments--presence-target="typingIndicator"></div>
        <textarea data-comments--presence-target="textarea"></textarea>
        <input type="checkbox" data-comments--presence-target="privateCheckbox" />
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--presence', PresenceController)

    await new Promise((resolve) => setTimeout(resolve, 0))
    const el = document.getElementById('comments-popup')
    controller = application.getControllerForElementAndIdentifier(el, 'comments--presence')
    controller.creativeId = '123'
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    delete document.body.dataset.currentUserId
    jest.restoreAllMocks()
  })

  test('hides comment input immediately when affected user loses comment permission', () => {
    const loadParticipantsSpy = jest.spyOn(controller, 'loadParticipants').mockImplementation(() => {})
    const setCommentPermission = jest.fn()
    const close = jest.fn()

    jest.spyOn(controller, 'formController', 'get').mockReturnValue({ setCommentPermission })
    jest.spyOn(controller, 'popupController', 'get').mockReturnValue({ close })
    jest.spyOn(controller, 'listController', 'get').mockReturnValue({ loadInitialComments: jest.fn() })

    controller.handlePresenceMessage({
      shares_changed: {
        user_id: 7,
        has_access: true,
        can_comment: false,
        has_access_changed: false,
        can_comment_changed: true,
      },
    })

    expect(setCommentPermission).toHaveBeenCalledWith(false)
    expect(loadParticipantsSpy).toHaveBeenCalledWith({ closeOnForbidden: false })
    expect(close).not.toHaveBeenCalled()
  })

  test('closes popup when affected user loses access', async () => {
    const close = jest.fn()
    jest.spyOn(controller, 'popupController', 'get').mockReturnValue({ close })
    jest.spyOn(controller, 'formController', 'get').mockReturnValue({ setCommentPermission: jest.fn() })

    global.fetch.mockResolvedValue({
      ok: false,
      json: async () => ({ error: 'No permission' }),
    })

    controller.handlePresenceMessage({
      shares_changed: {
        user_id: 7,
        has_access: false,
        can_comment: false,
        has_access_changed: true,
        can_comment_changed: true,
      },
    })

    await new Promise((resolve) => setTimeout(resolve, 0))

    // alertDialog renders an in-app modal (replacing native alert for the
    // Tauri webview); assert the message surfaced there instead.
    expect(document.querySelector('.confirm-dialog-message')?.textContent).toBe('No permission')
    expect(close).toHaveBeenCalled()
  })

  test('keeps popup open for unaffected users and only refreshes participants', () => {
    const loadParticipantsSpy = jest.spyOn(controller, 'loadParticipants').mockImplementation(() => {})
    const close = jest.fn()
    const setCommentPermission = jest.fn()
    const loadInitialComments = jest.fn()

    jest.spyOn(controller, 'popupController', 'get').mockReturnValue({ close })
    jest.spyOn(controller, 'formController', 'get').mockReturnValue({ setCommentPermission })
    jest.spyOn(controller, 'listController', 'get').mockReturnValue({ loadInitialComments })

    controller.handlePresenceMessage({
      shares_changed: {
        user_id: 99,
        has_access: true,
        can_comment: true,
        has_access_changed: false,
        can_comment_changed: false,
      },
    })

    expect(loadParticipantsSpy).toHaveBeenCalledWith()
    expect(setCommentPermission).not.toHaveBeenCalled()
    expect(loadInitialComments).not.toHaveBeenCalled()
    expect(close).not.toHaveBeenCalled()
  })

  test('bootstraps the selected and main topics when the popup opens', () => {
    const refreshChannelChips = jest.spyOn(controller, 'refreshChannelChips').mockImplementation(() => {})
    jest.spyOn(application, 'getControllerForElementAndIdentifier').mockReturnValue({
      currentTopicId: '45',
      mainTopicId: '10',
    })

    controller.bootstrapChannelChips()

    expect(controller.selectedTopicId).toBe('45')
    expect(controller.mainTopicId).toBe('10')
    expect(refreshChannelChips).toHaveBeenCalledWith('45')
  })

  test('clears topic timers when the popup closes', () => {
    const clearTopicTimers = jest.spyOn(controller, 'clearTopicTimers').mockImplementation(() => {})

    controller.onPopupClosed()

    expect(clearTopicTimers).toHaveBeenCalled()
  })

  test('sends typing lifecycle with the selected topic', () => {
    const perform = jest.fn()
    controller.presenceSubscription = { perform }
    controller.selectedTopicId = '45'

    controller.typing()
    controller.stoppedTyping()

    expect(perform).toHaveBeenNthCalledWith(1, 'typing', { topic_id: '45' })
    expect(perform).toHaveBeenNthCalledWith(2, 'stopped_typing', { topic_id: '45' })
  })

  test('sends All Messages input to Main but does not render topic indicators there', () => {
    const perform = jest.fn()
    controller.presenceSubscription = { perform }
    controller.selectedTopicId = null
    controller.mainTopicId = '10'

    controller.typing()
    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '10' } })

    expect(perform).toHaveBeenCalledWith('typing', { topic_id: '10' })
    expect(controller.typingUsers).toEqual({})
    controller.stoppedTyping()
  })

  test('shows typing only for the selected topic', () => {
    controller.selectedTopicId = '10'

    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '11' } })
    expect(controller.typingUsers).toEqual({})

    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '10' } })
    expect(controller.typingUsers).toEqual({ 5: 'Alice' })
  })

  test('ignores stop events from another topic', () => {
    controller.selectedTopicId = '10'
    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '10' } })

    controller.handlePresenceMessage({ stop_typing: { id: 5, topic_id: '11' } })
    expect(controller.typingUsers).toEqual({ 5: 'Alice' })

    controller.handlePresenceMessage({ stop_typing: { id: 5, topic_id: '10' } })
    expect(controller.typingUsers).toEqual({})
  })

  test('ignores agent idle events from another topic', () => {
    controller.selectedTopicId = '10'
    const status = {
      id: 9,
      name: 'Agent',
      status: 'thinking',
      task_id: 99,
      creative_id: '123',
      topic_id: '10',
    }
    controller.handlePresenceMessage({ agent_status: status })

    controller.handlePresenceMessage({
      agent_status: { ...status, status: 'idle', topic_id: '11' },
    })
    expect(controller.typingUsers).toEqual({ 9: 'Agent' })

    controller.handlePresenceMessage({
      agent_status: { ...status, status: 'idle' },
    })
    expect(controller.typingUsers).toEqual({})
  })

  test('clears typing and agent state immediately when switching topics', () => {
    const perform = jest.fn()
    controller.presenceSubscription = { perform }
    controller.selectedTopicId = '10'
    controller.mainTopicId = '1'
    controller.typingUsers = { 5: 'Alice', 9: 'Agent' }
    controller.activeAgentTasks = { 9: 99 }
    controller.typingTimers = { 5: setTimeout(() => {}, 1000) }
    controller.agentStatusTimers = { 9: setTimeout(() => {}, 1000) }
    jest.spyOn(controller, 'refreshChannelChips').mockImplementation(() => {})

    controller.handleTopicChange({ detail: { topicId: '11', mainTopicId: '1' } })

    expect(perform).toHaveBeenCalledWith('stopped_typing', { topic_id: '10' })
    expect(controller.selectedTopicId).toBe('11')
    expect(controller.typingUsers).toEqual({})
    expect(controller.activeAgentTasks).toEqual({})
    expect(controller.typingTimers).toEqual({})
    expect(controller.agentStatusTimers).toEqual({})
  })
})

describe('CommentsPresenceController typing-row horizontal scroll', () => {
  let application
  let container
  let controller
  let row
  let scrollLeftValue

  // jsdom has no layout engine, so scroll geometry must be stubbed. Treat the
  // row as 100px wide with 300px of content: "at end" means scrollLeft >= 176.
  function setGeometry({ clientWidth, scrollWidth, scrollLeft }) {
    scrollLeftValue = scrollLeft
    Object.defineProperty(row, 'clientWidth', { value: clientWidth, configurable: true })
    Object.defineProperty(row, 'scrollWidth', { value: scrollWidth, configurable: true })
    Object.defineProperty(row, 'scrollLeft', {
      configurable: true,
      get: () => scrollLeftValue,
      set: (v) => { scrollLeftValue = v },
    })
  }

  beforeEach(async () => {
    document.body.dataset.currentUserId = '7'
    global.fetch = jest.fn()

    container = document.createElement('div')
    container.innerHTML = `
      <div id="comments-popup" data-controller="comments--presence">
        <textarea data-comments--presence-target="textarea"></textarea>
        <input type="checkbox" data-comments--presence-target="privateCheckbox" />
        <div id="typing-indicator-row">
          <div id="typing-scroll-viewport" data-comments--presence-target="scrollRow">
            <div data-comments--presence-target="channelChips"></div>
            <div data-comments--presence-target="typingIndicator"></div>
          </div>
        </div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--presence', PresenceController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    const el = document.getElementById('comments-popup')
    controller = application.getControllerForElementAndIdentifier(el, 'comments--presence')
    controller.creativeId = '123'
    controller.selectedTopicId = '11'
    row = el.querySelector('#typing-scroll-viewport')
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    delete document.body.dataset.currentUserId
    jest.restoreAllMocks()
  })

  test('auto-scrolls a new typer into view when parked at the right edge', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 200 }) // at end

    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '11' } })

    expect(scrollLeftValue).toBe(300)
  })

  test('does NOT scroll when the user has scrolled back to look at earlier items', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 0 }) // scrolled back

    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '11' } })

    expect(scrollLeftValue).toBe(0)
  })

  test('does not re-scroll on repeat typing pings from the same user (not a new item)', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 200 })
    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '11' } })
    expect(scrollLeftValue).toBe(300)

    // User scrolls back; a heartbeat ping for the same (already-shown) typer
    // must not yank them to the end again.
    scrollLeftValue = 0
    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice', topic_id: '11' } })
    expect(scrollLeftValue).toBe(0)
  })

  test("always scrolls the local user's own new typing indicator into view, even when scrolled back to badges", () => {
    // currentUserId is '7'. The user is parked at the left looking at PR/Preview
    // badges (scrollLeft 0, not at end). When they themselves start typing they
    // always want to see their own indicator, so stick-to-end must not suppress it.
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 0 })

    controller.handlePresenceMessage({ typing: { id: 7, name: 'Me', topic_id: '11' } })

    expect(scrollLeftValue).toBe(300)
  })

  test('does not re-scroll on repeat self typing pings (only the first appearance forces scroll)', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 0 })
    controller.handlePresenceMessage({ typing: { id: 7, name: 'Me', topic_id: '11' } })
    expect(scrollLeftValue).toBe(300)

    // A heartbeat ping for the same (already-shown) self typer while scrolled
    // back must not yank to the end again — only the first appearance forces it.
    scrollLeftValue = 0
    controller.handlePresenceMessage({ typing: { id: 7, name: 'Me', topic_id: '11' } })
    expect(scrollLeftValue).toBe(0)
  })
})
