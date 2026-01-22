
/**
 * @jest-environment jsdom
 */

import { Application, Controller } from '@hotwired/stimulus'
import CommentsPopupController from '../popup_controller'

describe('CommentsPopupController', () => {
    let application
    let container
    let controller

    beforeEach(() => {
        container = document.createElement('div')
        container.innerHTML = `
      <div id="comments-popup" data-controller="comments--popup" style="width: 300px; height: 400px; position: absolute;">
        <h3 data-comments--popup-target="title">Title</h3>
        <div data-comments--popup-target="list">List</div>
        <button data-comments--popup-target="closeButton">Close</button>
        <div data-comments--popup-target="leftHandle"></div>
        <div data-comments--popup-target="rightHandle"></div>
      </div>
      <button id="trigger-btn" data-creative-id="123" data-can-comment="true">Open</button>
    `
        document.body.appendChild(container)

        application = Application.start()
        application.register('comments--popup', CommentsPopupController)

        // Manual controller access for testing internals if needed, 
        // though usually better to test via DOM/events.
        // Waiting for connection:
        return new Promise(resolve => setTimeout(resolve, 0)).then(() => {
            const element = document.getElementById('comments-popup')
            controller = application.getControllerForElementAndIdentifier(element, 'comments--popup')
        })
    })

    afterEach(() => {
        document.body.innerHTML = ''
        application.stop()
    })

    test('clears resized dataset attribute on close', () => {
        const triggerBtn = document.getElementById('trigger-btn')
        const popup = document.getElementById('comments-popup')

        // Open popup
        controller.open(triggerBtn)
        expect(popup.style.display).not.toBe('none')

        // Simulate resize start
        const leftHandle = popup.querySelector('[data-comments--popup-target="leftHandle"]')
        leftHandle.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: 100, clientY: 100 }))

        // Moving mouse to resize
        window.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 90, clientY: 100 }))

        expect(popup.dataset.resized).toBe('true')

        // Close popup
        controller.close()

        expect(popup.style.display).toBe('none')
        expect(popup.dataset.resized).toBeUndefined()
    })
})
