/**
 * @jest-environment jsdom
 */
import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'

const handleDrop = jest.fn()
jest.unstable_mockModule('../../../creatives/drag_drop/event_handlers', () => ({
  addGlobalListeners: jest.fn(),
  removeGlobalListeners: jest.fn(),
  handleDragStart: jest.fn(),
  handleDragOver: jest.fn(),
  handleDrop,
  handleDragLeave: jest.fn(),
}))
jest.unstable_mockModule('../../../creatives/drag_drop/indicator', () => ({
  initIndicator: jest.fn(),
}))

const { default: DragDropController } = await import('../drag_drop_controller')

test('passes the localized partial-failure fallback to the drop handler', async () => {
  document.body.innerHTML = `
    <div data-controller="creatives--drag-drop"
         data-creatives--drag-drop-partial-failure-text-value="일부 링크에 실패했습니다."></div>
  `
  const application = Application.start()
  application.register('creatives--drag-drop', DragDropController)
  await Promise.resolve()
  const element = document.querySelector('[data-controller="creatives--drag-drop"]')
  const controller = application.getControllerForElementAndIdentifier(
    element,
    'creatives--drag-drop'
  )
  const event = new Event('drop')

  controller.drop(event)

  expect(handleDrop).toHaveBeenCalledWith(event, {
    partialFailureMessage: '일부 링크에 실패했습니다.',
  })
  application.stop()
})
