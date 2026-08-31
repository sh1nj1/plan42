/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import TopicsController from '../topics_controller'

describe('TopicsController topic strip scrolling', () => {
    let application
    let controller
    let list
    let activeTopic
    let frames
    let nextFrameId

    beforeEach(async () => {
        document.body.innerHTML = `
          <div data-controller="comments--topics">
            <div data-comments--topics-target="list">
              <span class="topic-tag active" data-id="1"></span>
            </div>
          </div>
        `
        frames = new Map()
        nextFrameId = 1
        global.requestAnimationFrame = jest.fn(callback => {
            const frameId = nextFrameId++
            frames.set(frameId, callback)
            return frameId
        })
        global.cancelAnimationFrame = jest.fn(frameId => frames.delete(frameId))
        jest.spyOn(performance, 'now').mockReturnValue(0)
        application = Application.start()
        application.register('comments--topics', TopicsController)
        await new Promise(resolve => setTimeout(resolve, 0))

        const element = document.querySelector('[data-controller="comments--topics"]')
        controller = application.getControllerForElementAndIdentifier(element, 'comments--topics')
        list = controller.listTarget
        activeTopic = list.querySelector('.active')
        Object.defineProperties(list, {
            scrollLeft: { configurable: true, value: 0, writable: true },
            scrollWidth: { configurable: true, value: 1_000 },
            clientWidth: { configurable: true, value: 200 },
        })
        list.getBoundingClientRect = jest.fn(() => ({ left: 100, width: 200 }))
        activeTopic.getBoundingClientRect = jest.fn(() => ({ left: 800, width: 100 }))
    })

    afterEach(() => {
        application.stop()
        document.body.innerHTML = ''
        jest.restoreAllMocks()
        delete global.requestAnimationFrame
        delete global.cancelAnimationFrame
    })

    test.each(['wheel', 'touchstart'])(
        'cancels a smooth active-topic scroll when the user starts a %s gesture',
        eventName => {
            controller.scrollToActiveTopic()
            const firstFrameId = controller._topicScrollFrame
            const firstFrame = frames.get(firstFrameId)
            frames.delete(firstFrameId)
            firstFrame(50)
            const pendingFrameId = controller._topicScrollFrame
            const interruptedAt = list.scrollLeft

            list.dispatchEvent(new Event(eventName, { bubbles: true }))

            expect(cancelAnimationFrame).toHaveBeenCalledWith(pendingFrameId)
            expect(controller._topicScrollFrame).toBeNull()
            expect(frames.has(pendingFrameId)).toBe(false)
            expect(list.scrollLeft).toBe(interruptedAt)

            requestAnimationFrame.mockClear()
            controller.scrollToActiveTopic()

            expect(requestAnimationFrame).not.toHaveBeenCalled()
            expect(list.scrollLeft).toBe(interruptedAt)
        },
    )

    test('does not resume scrolling for a non-user pick', () => {
        list.dispatchEvent(new Event('wheel', { bubbles: true }))

        controller.updateSelectionUI('1', { pick: true, persist: false })

        expect(requestAnimationFrame).not.toHaveBeenCalled()
        expect(controller._topicScrollInterrupted).toBe(true)
    })

    test('allows a new active-topic scroll after an explicit user pick', () => {
        list.dispatchEvent(new Event('wheel', { bubbles: true }))

        controller.updateSelectionUI('1', {
            pick: true,
            persist: false,
            userInitiated: true,
        })

        expect(requestAnimationFrame).toHaveBeenCalledTimes(1)
        expect(controller._topicScrollInterrupted).toBe(false)
    })

    test('marks branch-icon navigation as user initiated', () => {
        activeTopic.dataset.sourceTopicId = '2'
        activeTopic.innerHTML = '<span class="topic-branch-icon"></span>'
        const selectTopic = jest.spyOn(controller, 'selectTopic').mockImplementation(() => {})

        controller.select({
            target: activeTopic.querySelector('.topic-branch-icon'),
            currentTarget: activeTopic,
        })

        expect(selectTopic).toHaveBeenCalledWith('2', { userInitiated: true })
    })

    test('finishes the active-topic scroll at the centered position', () => {
        controller.scrollToActiveTopic()
        const frame = frames.get(controller._topicScrollFrame)

        frame(250)

        expect(list.scrollLeft).toBe(650)
        expect(controller._topicScrollFrame).toBeNull()
    })

    test('does not schedule a scroll when the topic is already centered', () => {
        list.scrollLeft = 650
        activeTopic.getBoundingClientRect.mockReturnValue({ left: 150, width: 100 })

        controller.scrollToActiveTopic()

        expect(requestAnimationFrame).not.toHaveBeenCalled()
        expect(controller._topicScrollFrame).toBeNull()
    })

    test('cancels an active-topic scroll when the popup closes', () => {
        controller.scrollToActiveTopic()
        const pendingFrameId = controller._topicScrollFrame

        controller.onPopupClosed()

        expect(cancelAnimationFrame).toHaveBeenCalledWith(pendingFrameId)
        expect(controller._topicScrollFrame).toBeNull()

        requestAnimationFrame.mockClear()
        controller.scrollToActiveTopic()

        expect(requestAnimationFrame).not.toHaveBeenCalled()
    })

    test('allows All Messages to scroll into view after moving the selected topic away', () => {
        controller.creativeIdValue = '42'
        controller.serverLastTopicId = '1'
        controller._topicScrollInterrupted = true
        const interruptionStatesAtLoad = []
        controller.loadTopics = jest.fn(() => {
            interruptionStatesAtLoad.push(controller._topicScrollInterrupted)
        })

        controller.handleTopicMoved({ detail: { sourceCreativeId: '42', topicId: '1' } })

        expect(interruptionStatesAtLoad).toEqual([false])
    })

    test('preserves the user scroll lock when moving an inactive topic away', () => {
        controller.creativeIdValue = '42'
        controller.serverLastTopicId = '1'
        controller._topicScrollInterrupted = true
        const interruptionStatesAtLoad = []
        controller.loadTopics = jest.fn(() => {
            interruptionStatesAtLoad.push(controller._topicScrollInterrupted)
        })

        controller.handleTopicMoved({ detail: { sourceCreativeId: '42', topicId: '2' } })

        expect(interruptionStatesAtLoad).toEqual([true])
    })
})
