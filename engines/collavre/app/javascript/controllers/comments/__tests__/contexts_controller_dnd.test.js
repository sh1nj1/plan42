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
  document.body.innerHTML = `<div id="comments-popup" data-controller="comments--contexts" data-creative-id="42" data-context-update-error-text="Could not update contexts">
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
  controller.loadContexts = jest.fn().mockImplementation(async () => { controller._contextDropNeedsRefresh = false; return true })
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


test('rejected bundle keeps the existing view and reports the failure', async () => {
  controller._updateContextIds.mockResolvedValue(false)
  await controller._addDroppedContexts(['30', '40'])
  expect(controller.contexts.map(context => context.id)).toEqual([10, 20, 99])
  expect(controller.loadContexts).not.toHaveBeenCalled()
  expect(document.querySelector('[role="alertdialog"]').textContent).toContain('Could not update contexts')
  document.querySelector('[role="alertdialog"] button').click()
})

test('duplicate-only and invalid IDs never write', async () => {
  await controller._addDroppedContexts(['10', '99', '42', '0', '-1', '1.5', 'NaN'])
  expect(controller._updateContextIds).not.toHaveBeenCalled()
})

test('successive bundles preserve the preceding successful additions', async () => {
  controller.loadContexts.mockImplementation(async () => {
    controller.contexts = [{ id: 10 }, { id: 20 }, { id: 30 }]
    controller._contextDropNeedsRefresh = false
    return true
  })
  const first = controller._addDroppedContexts(['30'])
  const second = controller._addDroppedContexts(['40'])
  await Promise.all([first, second])
  expect(controller._updateContextIds.mock.calls).toEqual([[[10, 20, 30]], [[10, 20, 30, 40]]])
})

test('queued bundle is cancelled when the popup switches creative', async () => {
  const pending = controller._addDroppedContexts(['30'])
  popup.dataset.creativeId = '77'
  await pending
  expect(controller._updateContextIds).not.toHaveBeenCalled()
})


test.each([
  { ok: false, status: 403 },
  { ok: true, redirected: true },
  { ok: true, headers: { get: () => 'text/html' } },
])('context patch rejects failed or login responses: %j', async response => {
  const originalFetch = global.fetch
  global.fetch = jest.fn().mockResolvedValue(response)
  const error = jest.spyOn(console, 'error').mockImplementation(() => {})
  try {
    expect(await controller._sendContextPatch('42', { context_ids: [10, 30] })).toBe(false)
  } finally {
    global.fetch = originalFetch
    error.mockRestore()
  }
})

test('context patch requests a JSON response', async () => {
  const originalFetch = global.fetch
  global.fetch = jest.fn().mockResolvedValue({ ok: true, headers: { get: () => 'application/json' } })
  try {
    expect(await controller._sendContextPatch('42', { context_ids: [10, 30] })).toBe(true)
    expect(global.fetch).toHaveBeenCalledWith('/creatives/42/update_contexts', expect.objectContaining({
      headers: expect.objectContaining({ Accept: 'application/json' }),
    }))
  } finally {
    global.fetch = originalFetch
  }
})

test('context patch reports network uncertainty and successful writes distinctly', async () => {
  const originalFetch = global.fetch
  global.fetch = jest.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ ok: true })
  const error = jest.spyOn(console, 'error').mockImplementation(() => {})
  try {
    expect(await controller._sendContextPatch('42', { context_ids: [10, 30] })).toBe(false)
    expect(await controller._sendContextPatch('42', { context_ids: [10, 30] })).toBe(true)
  } finally {
    global.fetch = originalFetch
    error.mockRestore()
  }
})


test('failed reload blocks a later bundle from overwriting a successful addition', async () => {
  controller.loadContexts.mockResolvedValue(false)
  await controller._addDroppedContexts(['30'])
  document.querySelector('[role="alertdialog"] button').click()
  await controller._addDroppedContexts(['40'])
  expect(controller._updateContextIds.mock.calls).toEqual([[[10, 20, 30]]])
  document.querySelector('[role="alertdialog"] button').click()
})
