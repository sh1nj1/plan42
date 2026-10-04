/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const initIndicator = jest.fn()
const addGlobalListeners = jest.fn()
const removeGlobalListeners = jest.fn()
const registries = []
const createCreativeTreeDragDrop = jest.fn(() => {
  const registry = { destroy: jest.fn() }
  registries.push(registry)
  return registry
})
jest.unstable_mockModule('../../../creatives/drag_drop/indicator', () => ({ initIndicator }))
jest.unstable_mockModule('../../../creatives/drag_drop/event_handlers', () => ({
  addGlobalListeners, removeGlobalListeners, createCreativeTreeDragDrop,
}))
const fileRegistries = []
const createCreativeFileDrop = jest.fn(() => {
  const registry = { destroy: jest.fn() }
  fileRegistries.push(registry)
  return registry
})
jest.unstable_mockModule('../../../creatives/drag_drop/file_drop', () => ({ createCreativeFileDrop }))
const DragDropController = (await import('../drag_drop_controller')).default
const flush = () => new Promise(resolve => setTimeout(resolve, 0))

test('shares one gesture registry across tree mounts and releases it after the last Turbo disconnect', async () => {
  const application = Application.start()
  application.register('creatives--drag-drop', DragDropController)
  const mount = () => {
    const element = document.createElement('div')
    element.setAttribute('data-creatives--drag-drop-file-failure-text-value', '첨부 실패')
    element.dataset.controller = 'creatives--drag-drop'
    element.setAttribute('data-creatives--drag-drop-partial-failure-text-value', '일부 항목을 이동하지 못했습니다.')
    document.body.appendChild(element)
    return element
  }
  try {
    const first = mount()
    const second = mount()
    await flush()
    expect(createCreativeTreeDragDrop).toHaveBeenCalledTimes(1)
    expect(createCreativeTreeDragDrop).toHaveBeenCalledWith({ partialFailureMessage: '일부 항목을 이동하지 못했습니다.' })
    expect(createCreativeFileDrop).toHaveBeenCalledWith({ failureMessage: '첨부 실패' })
    expect(createCreativeFileDrop).toHaveBeenCalledTimes(1)
    expect(addGlobalListeners).toHaveBeenCalledTimes(1)

    first.remove()
    await flush()
    expect(registries[0].destroy).not.toHaveBeenCalled()
    expect(removeGlobalListeners).not.toHaveBeenCalled()

    second.remove()
    await flush()
    expect(fileRegistries[0].destroy).toHaveBeenCalledTimes(1)
    expect(registries[0].destroy).toHaveBeenCalledTimes(1)
    expect(removeGlobalListeners).toHaveBeenCalledTimes(1)

    document.body.appendChild(first)
    await flush()
    expect(createCreativeTreeDragDrop).toHaveBeenCalledTimes(2)
    expect(initIndicator).toHaveBeenCalledTimes(2)
    first.remove()
    await flush()
    expect(registries[1].destroy).toHaveBeenCalledTimes(1)
  } finally {
    document.body.innerHTML = ''
    await flush()
    application.stop()
  }
})
