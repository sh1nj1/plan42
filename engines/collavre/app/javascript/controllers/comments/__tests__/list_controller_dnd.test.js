/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import ListController from '../list_controller'
import { readDragData } from '../../../lib/dnd/envelope'

test('delegated selected comments preserve bundle IDs and release feedback on cancellation', () => {
  document.body.innerHTML = '<div id="popup"><div id="list"><div class="comment-item" draggable="true"><span class="comment-body">Message</span></div></div></div>'
  const controller = Object.create(ListController.prototype)
  Object.defineProperty(controller, 'element', { value: document.querySelector('#popup') })
  Object.defineProperty(controller, 'listTarget', { value: document.querySelector('#list') })
  controller.connect()
  controller.selection = new Set(['7', '9'])
  const values = {}
  const dataTransfer = { get types() { return Object.keys(values) }, getData: type => values[type] || '',
    setData: (type, value) => { values[type] = value }, setDragImage: jest.fn() }
  const event = new Event('dragstart', { bubbles: true, cancelable: true })
  Object.assign(event, { dataTransfer })
  controller.listTarget.querySelector('.comment-body').dispatchEvent(event)
  expect(readDragData(dataTransfer)).toEqual(expect.objectContaining({ kind: 'comments', ids: ['7', '9'] }))
  expect(JSON.parse(values['application/x-comment-ids'])).toEqual(['7', '9'])
  expect(controller.listTarget.classList.contains('dragging-comments')).toBe(true)
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
  expect(controller.listTarget.classList.contains('dragging-comments')).toBe(false)
  controller.disconnect()
  document.body.innerHTML = ''
})
