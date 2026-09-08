/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import TreeController from '../../../controllers/creatives/tree_controller'
import { addGlobalListeners, removeGlobalListeners } from '../event_handlers'
import { resetDragSessionCache } from '../../../lib/dnd/session'

let application, controller, load, container
const ids = () => [...container.querySelectorAll(':scope > creative-tree-row')].map(row => row.getAttribute('creative-id'))
const row = id => `<creative-tree-row creative-id="${id}" level="1"><div class="creative-tree" id="creative-${id}"></div></creative-tree-row>`
function signal(detail) {
  window.dispatchEvent(new StorageEvent('storage', {
    key: 'collavre.dragDropSignal',
    newValue: JSON.stringify({ sessionToken: 'verified-token', sourceWindowId: 'source-window', ...detail }),
  }))
}

beforeEach(async () => {
  document.body.innerHTML = `<div id="creatives" data-controller="creatives--tree" data-loaded="true">${[7, 8, 9].map(row).join('')}</div>`
  container = document.getElementById('creatives')
  localStorage.setItem('collavre.dragToken', 'verified-token')
  sessionStorage.setItem('collavre.dragWindowId', 'source-window')
  resetDragSessionCache()
  application = Application.start()
  application.register('creatives--tree', TreeController)
  await new Promise(resolve => setTimeout(resolve, 0))
  controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
  load = jest.spyOn(controller, 'load').mockImplementation(() => {})
  addGlobalListeners()
  jest.useFakeTimers()
})

afterEach(() => {
  removeGlobalListeners()
  controller.disconnect()
  application.stop()
  document.body.innerHTML = ''
  localStorage.clear()
  sessionStorage.clear()
  resetDragSessionCache()
  jest.useRealTimers()
  jest.restoreAllMocks()
})

test.each(['editing', 'operation hold'])('a verified bundle removes every moved row while reload waits for %s', reason => {
  const draft = document.createElement('textarea')
  draft.value = 'Unsaved draft'
  container.lastElementChild.appendChild(draft)
  if (reason === 'editing') document.dispatchEvent(new Event('creative-editing:start'))
  else controller.beginReloadHold()

  signal({ creativeId: '7', creativeIds: [7, '7', null, '', 8, '8'], treeId: 'creative-7', mode: 'move' })
  jest.advanceTimersByTime(400)
  expect(ids()).toEqual(['9'])
  expect(draft.isConnected).toBe(true)
  expect(draft.value).toBe('Unsaved draft')
  expect(load).not.toHaveBeenCalled()

  if (reason === 'editing') document.dispatchEvent(new Event('creative-editing:stop'))
  else controller.endReloadHold()
  jest.advanceTimersByTime(400)
  expect(load).toHaveBeenCalledTimes(1)
})

test.each([
  ['up', ['7', '8', '9']],
  ['down', ['9', '7', '8']],
])('array-only completion preserves bundle order for a local %s target', (direction, expected) => {
  controller.beginReloadHold()
  signal({ creativeIds: [7, 8, 7], direction, targetTreeId: 'creative-9', mode: 'move' })
  expect(ids()).toEqual(expected)
  expect(load).not.toHaveBeenCalled()
})

test('bundle children retain their order and parent metadata', () => {
  controller.beginReloadHold()
  signal({ creativeId: '7', creativeIds: [7, 8], treeId: 'creative-7', direction: 'child', targetTreeId: 'creative-9' })
  expect(ids()).toEqual(['9'])
  const children = [...container.querySelectorAll('creative-tree-row[parent-id="9"]')]
  expect(children.map(row => row.getAttribute('creative-id'))).toEqual(['7', '8'])
  expect(children.map(row => row.getAttribute('level'))).toEqual(['2', '2'])
})

test.each([undefined, [], [null, '']])('legacy scalar completion remains valid with creativeIds=%s', creativeIds => {
  controller.beginReloadHold()
  signal({ creativeId: 7, creativeIds, treeId: 'creative-7' })
  expect(ids()).toEqual(['8', '9'])
})

test('a partial-success array is authoritative over the legacy dragged row', () => {
  controller.beginReloadHold()
  signal({ creativeId: '7', creativeIds: [8], treeId: 'creative-7' })
  expect(ids()).toEqual(['7', '9'])
})

test('link completion never removes or reparents source rows', () => {
  controller.beginReloadHold()
  signal({ creativeId: '7', creativeIds: [7, 8], treeId: 'creative-7', mode: 'link',
    direction: 'child', targetTreeId: 'creative-9' })
  expect(ids()).toEqual(['7', '8', '9'])
  expect(container.querySelector('[parent-id]')).toBeNull()
})

test('a completion with no usable identifiers leaves the source untouched', () => {
  signal({ creativeIds: [null, ''] })
  jest.advanceTimersByTime(400)
  expect(ids()).toEqual(['7', '8', '9'])
  expect(load).not.toHaveBeenCalled()
})
