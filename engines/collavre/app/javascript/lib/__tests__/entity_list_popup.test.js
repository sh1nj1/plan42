import { jest } from '@jest/globals'
import { entityListPopup, closeEntityListPopup, toggleEntityListPopup } from '../entity_list_popup'

describe('entity list popup lifecycle', () => {
    let owner, open, setExpanded, popup
    beforeEach(() => {
        document.body.innerHTML = '<div id="owner"></div>'
        owner = { element: document.getElementById('owner'), application: { getControllerForElementAndIdentifier: jest.fn() } }
        open = jest.fn()
        setExpanded = jest.fn()
        popup = { close: jest.fn(), popup: { isOpen: jest.fn(() => false) } }
        global.requestAnimationFrame = fn => fn()
    })
    const toggle = () => toggleEntityListPopup({ owner, id: 'test-list', placeholder: 'Search', open, setExpanded })

    test('missing controller after creation logs the existing error and can be reused later', () => {
        const log = jest.spyOn(console, 'error').mockImplementation(() => {})
        toggle()
        expect(log).toHaveBeenCalledWith('entity-list controller not found after creation')
        expect(document.getElementById('test-list').dataset.closeLabel).toBe('')
        toggle()
        expect(open).not.toHaveBeenCalled()
        owner.application.getControllerForElementAndIdentifier.mockReturnValue(popup)
        toggle()
        expect(open).toHaveBeenCalledWith(popup)
        popup.popup.isOpen.mockReturnValue(true)
        toggle()
        expect(popup.close).toHaveBeenCalledTimes(1)
        expect(setExpanded).toHaveBeenCalledWith(false)
        log.mockRestore()
    })

    test('new modal opens when the controller connects', () => {
        owner.application.getControllerForElementAndIdentifier.mockReturnValue(popup)
        toggle()
        expect(open).toHaveBeenCalledWith(popup)
    })

    test('close removes only owned modal and handles missing controller', () => {
        owner.application.getControllerForElementAndIdentifier.mockReturnValue(popup)
        toggle()
        closeEntityListPopup(owner, 'test-list')
        expect(document.getElementById('test-list')).toBeNull()
        closeEntityListPopup(owner, 'test-list')
        expect(entityListPopup(owner, 'test-list')).toBeNull()
    })
})
