/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import ContextsController from '../contexts_controller'
import { writeDragData } from '../../../lib/dnd/envelope'

let application, controller, popup
function drag(type, target, values = {}, x = 0) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.assign(event, { clientX: x, dataTransfer: {
    get types() { return Object.keys(values) },
    getData: type => values[type] || '', setData: (type, value) => { values[type] = value }
  } })
  target.dispatchEvent(event)
  return event
}
function creativeValues(ids) {
  const values = {}
  writeDragData({ setData: (type, value) => { values[type] = value } },
    { kind: 'creative', ids, payload: { creativeId: ids[0], treeId: 'tree' } })
  return values
}
beforeEach(async () => {
  global.requestAnimationFrame = fn => { fn(); return 0 }
  document.body.innerHTML = `<div id="comments-popup" data-controller="comments--contexts" data-creative-id="42">
    <button data-comments--contexts-target="toggleButton"></button>
    <div data-comments--contexts-target="bar"><div data-comments--contexts-target="list"></div></div>
    <form id="new-comment-form"></form></div>`
  popup = document.getElementById('comments-popup')
  application = Application.start()
  application.register('comments--contexts', ContextsController)
  await new Promise(resolve => setTimeout(resolve, 0))
  controller = application.getControllerForElementAndIdentifier(popup, 'comments--contexts')
  controller.canManage = true
  controller.contexts = [{ id: 10 }, { id: 20 }, { id: 99, inherited: true }]
  controller._updateContextIds = jest.fn().mockResolvedValue()
  controller.loadContexts = jest.fn().mockResolvedValue()
  controller.renderContexts()
  controller._bindPopupDragDetection()
})
afterEach(() => {
  controller.disconnect()
  application.stop()
  document.body.innerHTML = ''
})

test('creative bundle is added in one command, excluding inherited and existing contexts', async () => {
  const values = creativeValues(['10', '30', '40', '99', '30'])
  const over = drag('dragover', controller.listTarget, values)
  expect(over.defaultPrevented).toBe(true)
  expect(controller.listTarget.classList.contains('dnd-over-into')).toBe(true)
  drag('drop', controller.listTarget, values)
  await Promise.resolve()
  expect(controller._updateContextIds).toHaveBeenCalledTimes(1)
  expect(controller._updateContextIds).toHaveBeenCalledWith([10, 20, 30, 40])
  expect(controller.listTarget.classList.contains('dnd-over-into')).toBe(false)
})

test('form and unauthorized drops never add contexts', () => {
  const values = creativeValues(['30'])
  drag('drop', document.querySelector('form'), values)
  controller.canManage = false
  drag('drop', controller.listTarget, values)
  expect(controller._updateContextIds).not.toHaveBeenCalled()
})

test('context reorder uses delegated rows after rendering and rejects self and inherited destinations', async () => {
  const values = {}
  const source = popup.querySelector('[data-context-id="10"]')
  const target = popup.querySelector('[data-context-id="20"]')
  drag('dragstart', source, values)
  expect(values['application/x-context-id']).toBe('10')
  expect(drag('dragover', source, values).defaultPrevented).toBe(false)
  expect(drag('dragover', popup.querySelector('[data-context-id="99"]'), values).defaultPrevented).toBe(false)
  drag('drop', target, values, 10)
  await Promise.resolve()
  expect(controller._updateContextIds).toHaveBeenCalledWith([20, 10])
  drag('dragend', source, values)
  expect(source.classList.contains('context-dragging')).toBe(false)
})

test('leaving an empty popup restores hidden context list', () => {
  controller.contexts = []
  const values = creativeValues(['30'])
  drag('dragover', popup, values)
  expect(controller.listVisible).toBe(true)
  drag('dragleave', popup, values)
  expect(controller.listVisible).toBe(false)
})
