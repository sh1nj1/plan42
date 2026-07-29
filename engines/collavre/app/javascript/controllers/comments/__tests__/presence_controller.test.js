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

    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice' } })

    expect(scrollLeftValue).toBe(300)
  })

  test('does NOT scroll when the user has scrolled back to look at earlier items', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 0 }) // scrolled back

    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice' } })

    expect(scrollLeftValue).toBe(0)
  })

  test('does not re-scroll on repeat typing pings from the same user (not a new item)', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 200 })
    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice' } })
    expect(scrollLeftValue).toBe(300)

    // User scrolls back; a heartbeat ping for the same (already-shown) typer
    // must not yank them to the end again.
    scrollLeftValue = 0
    controller.handlePresenceMessage({ typing: { id: 5, name: 'Alice' } })
    expect(scrollLeftValue).toBe(0)
  })

  test("always scrolls the local user's own new typing indicator into view, even when scrolled back to badges", () => {
    // currentUserId is '7'. The user is parked at the left looking at PR/Preview
    // badges (scrollLeft 0, not at end). When they themselves start typing they
    // always want to see their own indicator, so stick-to-end must not suppress it.
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 0 })

    controller.handlePresenceMessage({ typing: { id: 7, name: 'Me' } })

    expect(scrollLeftValue).toBe(300)
  })

  test('does not re-scroll on repeat self typing pings (only the first appearance forces scroll)', () => {
    setGeometry({ clientWidth: 100, scrollWidth: 300, scrollLeft: 0 })
    controller.handlePresenceMessage({ typing: { id: 7, name: 'Me' } })
    expect(scrollLeftValue).toBe(300)

    // A heartbeat ping for the same (already-shown) self typer while scrolled
    // back must not yank to the end again — only the first appearance forces it.
    scrollLeftValue = 0
    controller.handlePresenceMessage({ typing: { id: 7, name: 'Me' } })
    expect(scrollLeftValue).toBe(0)
  })

  describe('agent task status poll', () => {
    const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

    const respondWith = (tasks) => {
      global.fetch.mockResolvedValueOnce({
        ok: true,
        headers: new Headers(),
        json: async () => ({ tasks }),
      })
    }

    const armAgent = (agentId, taskIds) => {
      controller.activeAgentTasks[agentId] = [...taskIds]
      controller.typingUsers[agentId] = 'Agent'
      controller.agentStates[agentId] = 'thinking'
    }

    test('drops a task the poll reports as finished', async () => {
      armAgent('9', [55])
      respondWith([{ id: 55, active: false }])

      controller.pollAgentTaskStatuses()
      await flush()

      expect(controller.activeAgentTasks['9']).toBeUndefined()
      expect(controller.typingUsers['9']).toBeUndefined()
    })

    // Which statuses count as active is the server's call (Task#active?), covered
    // in tasks_controller_test.rb — here it only has to be believed.
    test('keeps a task the poll still reports as active', async () => {
      armAgent('9', [55])
      respondWith([{ id: 55, active: true }])

      controller.pollAgentTaskStatuses()
      await flush()

      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.typingUsers['9']).toBe('Agent')
    })

    test('keeps a task that started after the poll request was sent', async () => {
      armAgent('9', [55])

      let settle
      global.fetch.mockReturnValueOnce(
        new Promise((resolve) => {
          settle = resolve
        }),
      )

      controller.pollAgentTaskStatuses()

      // A second turn starts while the request is in flight. The server was
      // never asked about 77, so its absence from the response says nothing.
      controller.activeAgentTasks['9'].push(77)

      settle({
        ok: true,
        headers: new Headers(),
        json: async () => ({ tasks: [{ id: 55, active: true }] }),
      })
      await flush()

      expect(controller.activeAgentTasks['9']).toEqual([55, 77])
    })

    // A blip must not do what the old 10s timeout did: take the indicator, and
    // with it the only Stop button, off screen while the turn is still running.
    test('a failed poll leaves the turn alone', async () => {
      jest.spyOn(console, 'warn').mockImplementation(() => {})
      armAgent('9', [55])
      global.fetch.mockRejectedValueOnce(new Error('offline'))

      controller.pollAgentTaskStatuses()
      await flush()

      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.typingUsers['9']).toBe('Agent')
    })

    test('a poll with nothing left to ask about stops itself', () => {
      controller.startAgentTaskPoll()

      controller.pollAgentTaskStatuses()

      expect(controller.agentTaskPollHandle).toBeNull()
      expect(global.fetch).not.toHaveBeenCalled()
    })

    test('still drops a requested task even when a newer one arrived mid-flight', async () => {
      armAgent('9', [55])

      let settle
      global.fetch.mockReturnValueOnce(
        new Promise((resolve) => {
          settle = resolve
        }),
      )

      controller.pollAgentTaskStatuses()
      controller.activeAgentTasks['9'].push(77)

      settle({
        ok: true,
        headers: new Headers(),
        json: async () => ({ tasks: [{ id: 55, active: false }] }),
      })
      await flush()

      expect(controller.activeAgentTasks['9']).toEqual([77])
    })
  })

  describe('agent_status for a task paused on approval', () => {
    const agentStatus = (status) => ({
      agent_status: { id: 9, name: 'Agent', status, task_id: 55, creative_id: '123' },
    })

    beforeEach(() => {
      controller.handlePresenceMessage(agentStatus('streaming'))
      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.agentTaskPollHandle).not.toBeNull()
    })

    // The server pauses the task on pending_approval while it still holds the
    // topic slot and still accepts cancel. Dropping it here would also stop the
    // poll, so nothing would ever observe that status.
    test('keeps the task and the poll, and still offers Stop', () => {
      controller.handlePresenceMessage(agentStatus('pending_approval'))

      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.typingUsers['9']).toBe('Agent')
      expect(controller.agentTaskPollHandle).not.toBeNull()
      expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).not.toBeNull()
    })

    // The other direction: a genuinely finished turn must still clear at once,
    // rather than lingering until the next poll.
    test('idle still drops the task and stops the poll', () => {
      controller.handlePresenceMessage(agentStatus('idle'))

      expect(controller.activeAgentTasks['9']).toBeUndefined()
      expect(controller.typingUsers['9']).toBeUndefined()
      expect(controller.agentTaskPollHandle).toBeNull()
    })

    // idle is broadcast more than once per turn (finalize, then teardown), and a
    // reconnecting client can also replay one for a turn it never registered. The
    // second one has no task list to walk and must still be a clean no-op.
    test('a repeat idle for an agent with no task left is harmless', () => {
      controller.handlePresenceMessage(agentStatus('idle'))
      controller.typingUsers['9'] = 'Agent'
      controller.agentStates['9'] = 'thinking'

      controller.handlePresenceMessage(agentStatus('idle'))

      expect(controller.typingUsers['9']).toBeUndefined()
      expect(controller.agentStates['9']).toBeUndefined()
    })
  })

  describe('indicator label per agent state', () => {
    const agentStatus = (status) => ({
      agent_status: { id: 9, name: 'Agent', status, task_id: 55, creative_id: '123' },
    })
    const label = () => controller.typingIndicatorTarget.lastChild.textContent

    test('streaming reads as typing', () => {
      controller.handlePresenceMessage(agentStatus('streaming'))

      expect(label()).toBe('Agent ...')
    })

    test('thinking reads as waiting', () => {
      controller.handlePresenceMessage(agentStatus('thinking'))

      expect(label()).toBe('Agent ⏳')
    })

    // The reported bug: a long turn used to make the whole indicator (and with
    // it the only Stop button) disappear. It must degrade to waiting instead.
    test('a stalled stream degrades to waiting and keeps Stop reachable', () => {
      jest.useFakeTimers()
      try {
        controller.handlePresenceMessage(agentStatus('streaming'))
        expect(label()).toBe('Agent ...')

        jest.advanceTimersByTime(5000)

        expect(label()).toBe('Agent ⏳')
        expect(controller.activeAgentTasks['9']).toEqual([55])
        expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).not.toBeNull()
      } finally {
        jest.useRealTimers()
      }
    })

    // Each heartbeat re-arms the timer, so a stream that keeps reporting never
    // flips to waiting.
    test('a live heartbeat keeps it typing', () => {
      jest.useFakeTimers()
      try {
        controller.handlePresenceMessage(agentStatus('streaming'))
        jest.advanceTimersByTime(3000)
        controller.handlePresenceMessage(agentStatus('streaming'))
        jest.advanceTimersByTime(3000)

        expect(label()).toBe('Agent ...')
      } finally {
        jest.useRealTimers()
      }
    })

    // The scheduler runs more than one turn per agent (topic concurrency > 1),
    // and the heartbeat timer is per agent, not per turn. One turn going idle
    // must not disarm the timer the surviving turn still depends on, or that
    // turn stays labelled as typing forever once its stream goes quiet.
    test('one turn ending leaves the other turn able to degrade to waiting', () => {
      const statusFor = (status, taskId) => ({
        agent_status: { id: 9, name: 'Agent', status, task_id: taskId, creative_id: '123' },
      })
      jest.useFakeTimers()
      try {
        controller.handlePresenceMessage(statusFor('streaming', 55))
        controller.handlePresenceMessage(statusFor('streaming', 66))

        controller.handlePresenceMessage(statusFor('idle', 55))
        expect(controller.activeAgentTasks['9']).toEqual([66])
        expect(label()).toBe('Agent ...')

        jest.advanceTimersByTime(5000)

        expect(label()).toBe('Agent ⏳')
        expect(controller.activeAgentTasks['9']).toEqual([66])
        expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).not.toBeNull()
      } finally {
        jest.useRealTimers()
      }
    })

    test('a human typer is never labelled as waiting', () => {
      controller.typingUsers['7'] = 'Human'
      controller.renderTypingIndicator()

      expect(label()).toBe('Human ...')
    })
  })

  describe('navigating the open popup to another creative', () => {
    beforeEach(() => {
      // onPopupOpened's other work needs a cable and a server; neither is the
      // subject here.
      jest.spyOn(controller, 'loadParticipants').mockImplementation(() => {})
      jest.spyOn(controller, 'subscribe').mockImplementation(() => {})
      jest.spyOn(controller, 'bootstrapChannelChips').mockImplementation(() => {})

      controller.handlePresenceMessage({
        agent_status: { id: 9, name: 'Agent', status: 'streaming', task_id: 55, creative_id: '123' },
      })
      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.agentTaskPollHandle).not.toBeNull()
    })

    // The popup is never closed on navigation — PopupController#_navigateToEntry
    // reuses open()/openForCreative() — so onPopupClosed() does not run and this
    // is the only place that can drop the previous chat's state. Left behind, the
    // poll keeps asking about a task in another creative, active_statuses answers
    // for it (it only checks readability), and the indicator plus a Stop button
    // for that foreign turn stay on screen.
    test('drops the previous chat’s agent state and stops the poll', () => {
      controller.onPopupOpened({ creativeId: '456' })

      expect(controller.activeAgentTasks).toEqual({})
      expect(controller.typingUsers).toEqual({})
      expect(controller.agentStates).toEqual({})
      expect(controller.agentTaskPollHandle).toBeNull()
      expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).toBeNull()
    })

    // Scoped to an actual change of creative: re-opening the same chat must not
    // blank a turn that is streaming in it right now, which would leave it
    // invisible (and uncancellable) until the next 3s heartbeat.
    test('keeps it when the same creative is re-opened', () => {
      controller.onPopupOpened({ creativeId: 123 })

      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.typingUsers['9']).toBe('Agent')
      expect(controller.agentTaskPollHandle).not.toBeNull()
    })
  })

  describe('stopping a turn', () => {
    const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
    const cancelOk = () => global.fetch.mockResolvedValueOnce({ ok: true, headers: new Headers() })
    const cancelledUrls = () => global.fetch.mock.calls.map(([url]) => url)

    const arrive = (status, { agentId = 9, taskId = 55, name = 'Agent' } = {}) =>
      controller.handlePresenceMessage({
        agent_status: { id: agentId, name, status, task_id: taskId, creative_id: '123' },
      })

    test('the Stop button cancels the turn and takes the indicator down with it', async () => {
      arrive('streaming')
      cancelOk()

      controller.typingIndicatorTarget.querySelector('.agent-stop-btn').click()
      await flush()

      expect(cancelledUrls()).toEqual(['/tasks/55/cancel'])
      expect(controller.activeAgentTasks['9']).toBeUndefined()
      expect(controller.typingUsers['9']).toBeUndefined()
      expect(controller.agentStates['9']).toBeUndefined()
      expect(controller.agentTaskPollHandle).toBeNull()
      expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).toBeNull()
    })

    // One Stop button stands for one agent, so it has to mean the turn the user
    // is watching — the newest — not whichever turn happened to start first.
    test('Stop ends the newest turn when an agent has two in flight', async () => {
      arrive('streaming', { taskId: 55 })
      arrive('streaming', { taskId: 77 })
      cancelOk()

      controller.typingIndicatorTarget.querySelector('.agent-stop-btn').click()
      await flush()

      expect(cancelledUrls()).toEqual(['/tasks/77/cancel'])
      // The other turn is still running, so the agent — and its Stop button — stay.
      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.typingUsers['9']).toBe('Agent')
      expect(controller.agentTaskPollHandle).not.toBeNull()
      expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).not.toBeNull()
    })

    // A cancel that lands after the same task was already dropped (an idle
    // broadcast, or a poll that saw it finish) must still clear the name.
    test('cancelling a turn already dropped elsewhere still clears the agent', async () => {
      arrive('streaming')
      delete controller.activeAgentTasks['9']
      cancelOk()

      controller.cancelAgentTask(55, '9')
      await flush()

      expect(controller.typingUsers['9']).toBeUndefined()
      expect(controller.agentStates['9']).toBeUndefined()
      expect(controller.streamingHeartbeatTimers['9']).toBeUndefined()
    })

    test('a rejected cancel leaves the turn on screen', async () => {
      arrive('streaming')
      global.fetch.mockResolvedValueOnce({ ok: false, headers: new Headers() })

      controller.cancelAgentTask(55, '9')
      await flush()

      expect(controller.activeAgentTasks['9']).toEqual([55])
      expect(controller.typingIndicatorTarget.querySelector('.agent-stop-btn')).not.toBeNull()
    })

    // Escape in the composer routes here (form_controller keydown). Returning
    // false is what lets that handler fall through to its other behaviour.
    test('Escape reports false when there is nothing to stop', () => {
      expect(controller.cancelAllAgentTasks()).toBe(false)
      expect(global.fetch).not.toHaveBeenCalled()
    })

    test('Escape stops the newest turn of every agent', async () => {
      arrive('streaming', { agentId: 9, taskId: 55 })
      arrive('streaming', { agentId: 9, taskId: 77 })
      arrive('streaming', { agentId: 10, taskId: 88, name: 'Other' })
      cancelOk()
      cancelOk()

      expect(controller.cancelAllAgentTasks()).toBe(true)
      await flush()

      expect(cancelledUrls()).toEqual(['/tasks/77/cancel', '/tasks/88/cancel'])
    })
  })

  // The poll interval and the heartbeat timeouts write back into state the
  // indicator renders from. Leaving them armed for a chat nobody is looking at
  // keeps fetching /tasks/active_statuses forever and can repaint a torn-down row.
  describe('leaving the chat', () => {
    beforeEach(() => {
      jest.spyOn(controller, 'unsubscribe').mockImplementation(() => {})
      controller.handlePresenceMessage({
        agent_status: { id: 9, name: 'Agent', status: 'streaming', task_id: 55, creative_id: '123' },
      })
      expect(controller.agentTaskPollHandle).not.toBeNull()
      expect(controller.streamingHeartbeatTimers['9']).toBeDefined()
    })

    test('closing the popup disarms the poll and the heartbeats', () => {
      controller.onPopupClosed()

      expect(controller.agentTaskPollHandle).toBeNull()
      expect(controller.streamingHeartbeatTimers).toEqual({})
      expect(controller.activeAgentTasks).toEqual({})
      expect(controller.typingUsers).toEqual({})
    })

    test('disconnecting the controller disarms the poll and the heartbeats', () => {
      controller.disconnect()

      expect(controller.agentTaskPollHandle).toBeNull()
      expect(controller.streamingHeartbeatTimers).toEqual({})
    })
  })
})
