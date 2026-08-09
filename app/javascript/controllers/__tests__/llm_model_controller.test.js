/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import LlmModelController from '../llm_model_controller'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('LlmModelController', () => {
    let application
    let controller

    const models = [
        { id: 1, vendor: 'google', name: 'gemini-3.1-flash-lite', delete_url: '/llm_models/1' },
        { id: 2, vendor: 'openai', name: 'gpt-5.2', delete_url: '/llm_models/2' },
        { id: 3, vendor: 'openai', name: '<img src=x onerror=alert(1)>', delete_url: '/llm_models/3' }
    ]

    const mount = async () => {
        document.body.innerHTML = `
          <meta name="csrf-token" content="test-token">
          <div id="llm-fields" data-controller="llm-model"
               data-llm-model-menu-id-value="llm-model-suggestions"
               data-llm-model-delete-label-value="Remove"
               data-llm-model-delete-failed-value="Delete failed">
            <select data-llm-model-target="vendor">
              <option value="google">Google</option>
              <option value="openai" selected>OpenAI</option>
            </select>
            <input data-llm-model-target="input">
            <div id="llm-model-suggestions" style="display:none;">
              <ul class="common-popup-list"></ul>
            </div>
          </div>
        `
        document.getElementById('llm-fields').dataset.llmModelModelsValue = JSON.stringify(models)

        application = Application.start()
        application.register('llm-model', LlmModelController)
        await flush()
        controller = application.getControllerForElementAndIdentifier(
            document.getElementById('llm-fields'),
            'llm-model'
        )
    }

    beforeEach(async () => {
        global.requestAnimationFrame = (callback) => callback()
        global.fetch = jest.fn()
        window.HTMLElement.prototype.scrollIntoView = jest.fn()
        await mount()
    })

    afterEach(() => {
        application.stop()
        document.body.innerHTML = ''
        jest.clearAllMocks()
    })

    test('filters suggestions by the selected vendor and search term', () => {
        controller.show('gpt')

        const labels = Array.from(document.querySelectorAll('.llm-model-name'), (element) => element.textContent)
        expect(labels).toEqual(['gpt-5.2'])

        controller.vendorTarget.value = 'google'
        controller.vendorChanged()
        expect(document.querySelector('.llm-model-name').textContent).toBe('gemini-3.1-flash-lite')
    })

    test('selects a model without including the delete control', () => {
        controller.show('gpt')
        document.querySelector('.llm-model-name').dispatchEvent(new MouseEvent('click', { bubbles: true }))

        expect(controller.inputTarget.value).toBe('gpt-5.2')
    })

    test('renders saved model names as text instead of executable markup', () => {
        controller.show('img')

        expect(document.querySelector('.llm-model-item img')).toBeNull()
        expect(document.querySelector('.llm-model-name').textContent).toBe('<img src=x onerror=alert(1)>')
    })

    test('deletes a suggestion without selecting it', async () => {
        global.fetch.mockResolvedValue({ ok: true })
        controller.inputTarget.value = 'gpt'
        controller.show('gpt')

        document.querySelector('.llm-model-delete').dispatchEvent(new MouseEvent('click', { bubbles: true }))
        await flush()

        expect(global.fetch).toHaveBeenCalledWith('/llm_models/2', {
            method: 'DELETE',
            headers: { Accept: 'application/json', 'X-CSRF-Token': 'test-token' }
        })
        expect(controller.inputTarget.value).toBe('gpt')
        expect(controller.modelsValue.map((model) => model.id)).toEqual([1, 3])
    })

    test('keeps the suggestion and shows a localized error when deletion fails', async () => {
        global.fetch.mockResolvedValue({ ok: false, status: 500 })
        controller.show('gpt')

        document.querySelector('.llm-model-delete').dispatchEvent(new MouseEvent('click', { bubbles: true }))
        await flush()

        expect(document.querySelector('.confirm-dialog-message').textContent).toBe('Delete failed')
        document.querySelector('.modal-dialog-btn-primary').click()
        await flush()
        expect(controller.modelsValue.map((model) => model.id)).toEqual([1, 2, 3])
    })
})
