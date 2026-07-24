/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import TopicListController from '../topic_list_controller'

describe('TopicListController', () => {
    let application, controller

    const mount = () => {
        document.body.innerHTML = `
          <div id="topic-list-modal" class="common-popup" data-controller="topic-list">
            <button data-topic-list-target="close">×</button>
            <input data-topic-list-target="input">
            <ul class="common-popup-list" data-popup-list data-topic-list-target="list"></ul>
          </div>
        `
        application = Application.start()
        application.register('topic-list', TopicListController)
        return new Promise((resolve) => setTimeout(resolve, 0)).then(() => {
            controller = application.getControllerForElementAndIdentifier(
                document.getElementById('topic-list-modal'), 'topic-list'
            )
        })
    }

    const RECT = { top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0 }
    const DATA = {
        topics: [{ id: 1, name: 'Main' }, { id: 2, name: 'Alpha' }],
        archivedTopics: [{ id: 3, name: 'Zeta' }],
        mainTopicId: '1',
        allMessagesLabel: 'All Messages'
    }

    const items = () => Array.from(document.querySelectorAll('#topic-list-modal li.common-popup-item'))

    beforeEach(() => {
        global.requestAnimationFrame = (fn) => { fn(); return 0 }
        return mount()
    })

    afterEach(() => {
        document.body.innerHTML = ''
        application.stop()
        jest.clearAllMocks()
    })

    test('builds items in bar order: main, others, All Messages, archived', () => {
        controller.openForTopics(DATA, RECT, () => {})
        const labels = items().map((li) => li.textContent.trim())
        expect(labels).toEqual(['#Main', '#Alpha', '📋 All Messages', '#Zeta'])
    })

    test('marks archived items with the distinguishing class', () => {
        controller.openForTopics(DATA, RECT, () => {})
        const archived = items().filter((li) => li.querySelector('.topic-list-item--archived'))
        expect(archived).toHaveLength(1)
        expect(archived[0].textContent).toContain('#Zeta')
    })

    test('filters by label substring and adds NO create option', () => {
        controller.openForTopics(DATA, RECT, () => {})
        controller.inputTarget.value = 'alpha'
        controller._onInput()
        const labels = items().map((li) => li.textContent.trim())
        expect(labels).toEqual(['#Alpha'])

        controller.inputTarget.value = 'brandnew'
        controller._onInput()
        expect(items()).toHaveLength(0) // no "create and move" pseudo-item
    })

    test('select invokes the callback with the item and closes', () => {
        const cb = jest.fn()
        controller.openForTopics(DATA, RECT, cb)
        const item = { id: 2, label: '#Alpha', archived: false }
        controller.select(item)
        expect(cb).toHaveBeenCalledWith(item)
        expect(controller.popup.isOpen()).toBe(false)
    })
})
