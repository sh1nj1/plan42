/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import TopicsController from '../topics_controller'

let application, controller
function drag(type, target, values) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.assign(event, { clientX: 10, dataTransfer: {
    get types() { return Object.keys(values) }, getData: type => values[type] || '',
    setData: (type, value) => { values[type] = value }
  } })
  target.dispatchEvent(event)
  return event
}
beforeEach(async () => {
  global.requestAnimationFrame = fn => { fn(); return 0 }
  document.body.innerHTML = `<div id="comments-popup" data-controller="comments--topics">
    <div data-comments--topics-target="list"></div>
    <span data-comments--topics-target="creationContainer"></span></div>`
  application = Application.start()
  application.register('comments--topics', TopicsController)
  await new Promise(resolve => setTimeout(resolve, 0))
  controller = application.getControllerForElementAndIdentifier(document.querySelector('#comments-popup'), 'comments--topics')
  controller.creativeIdValue = '42'
  controller.canManageTopics = true
  controller.topics = [{ id: 1, name: 'First' }, { id: 2, name: 'Second' }, { id: 3, name: 'Read only', read_only: true }]
  controller.renderTopics(controller.topics, true)
  controller.saveTopicOrder = jest.fn().mockResolvedValue()
  controller.setTopicPrimaryAgent = jest.fn().mockResolvedValue()
  controller.createTopicWithAgent = jest.fn().mockResolvedValue()
  controller.createTopicAndMoveComments = jest.fn().mockResolvedValue()
})
afterEach(() => {
  controller.disconnect()
  application.stop()
  document.body.innerHTML = ''
})

test('topic source preserves reorder and cross-creative move MIME and reorders from normalized data', async () => {
  const values = {}
  const source = controller.listTarget.querySelector('[data-id="1"]')
  drag('dragstart', source, values)
  expect(values['application/x-topic-id']).toBe('1')
  expect(JSON.parse(values['application/x-topic-move'])).toEqual({ topicId: '1', sourceCreativeId: '42' })
  drag('drop', controller.listTarget.querySelector('[data-id="2"]'), values)
  await Promise.resolve()
  expect(controller.saveTopicOrder).toHaveBeenCalledWith([2, 1, 3])
  drag('dragend', source, values)
  expect(source.classList.contains('topic-dragging')).toBe(false)
})

test('agent and comments drops retain their different commands and read-only policy', async () => {
  const agent = { id: 8, name: 'Agent', avatar_url: '/agent.png' }
  const agentValues = { 'application/x-agent-drop': JSON.stringify(agent) }
  const commentValues = { 'application/x-comment-ids': JSON.stringify(['7', '9']) }
  const target = controller.listTarget.querySelector('[data-id="2"]')
  const moved = jest.fn()
  controller.element.addEventListener('comments--topics:move-to-topic', moved)
  expect(drag('dragover', target, agentValues).dataTransfer.dropEffect).toBe('copy')
  drag('drop', target, agentValues)
  drag('drop', target, commentValues)
  drag('drop', controller.creationContainerTarget, agentValues)
  drag('drop', controller.creationContainerTarget, commentValues)
  expect(drag('dragover', controller.listTarget.querySelector('[data-id="3"]'), agentValues).defaultPrevented).toBe(false)
  await Promise.resolve()
  expect(controller.setTopicPrimaryAgent).toHaveBeenCalledWith('2', { ...agent, id: '8' })
  expect(moved.mock.calls[0][0].detail).toEqual({ targetTopicId: '2', commentIds: ['7', '9'] })
  expect(controller.createTopicWithAgent).toHaveBeenCalledWith({ ...agent, id: '8' })
  expect(controller.createTopicAndMoveComments).toHaveBeenCalledWith(['7', '9'])
})
