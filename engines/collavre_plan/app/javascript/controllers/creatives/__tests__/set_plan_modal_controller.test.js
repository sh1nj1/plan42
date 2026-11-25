/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const alertDialog = jest.fn()
jest.unstable_mockModule('collavre/lib/utils/dialog', () => ({ alertDialog }))

const { default: SetPlanModalController } = await import('../set_plan_modal_controller')

describe('SetPlanModalController plan requests', () => {
  let application
  const originalFetch = global.fetch

  async function mount({ checked = ['3', '5'], planId = '9' } = {}) {
    document.head.innerHTML = '<meta name="csrf-token" content="token-1">'
    document.body.innerHTML = `
      <input type="checkbox" class="select-creative-checkbox" value="3">
      <input type="checkbox" class="select-creative-checkbox" value="4">
      <input type="checkbox" class="select-creative-checkbox" value="5">
      <div data-controller="set-plan-modal"
           data-set-plan-modal-select-one-value="Select a creative"
           data-set-plan-modal-select-plan-value="Select a plan">
        <div data-set-plan-modal-target="modal" style="display:flex">
          <form data-set-plan-modal-target="form" action="/plans/assign"
                data-action="submit->set-plan-modal#submit">
            <input type="hidden" data-set-plan-modal-target="idsInput">
            <select data-set-plan-modal-target="planSelect">
              <option value=""></option>
              <option value="9">Plan</option>
            </select>
            <button type="button" id="remove" data-remove-path="/plans/unassign"
                    data-action="click->set-plan-modal#remove"></button>
          </form>
        </div>
      </div>
    `
    document.querySelectorAll('.select-creative-checkbox').forEach((checkbox) => {
      checkbox.checked = checked.includes(checkbox.value)
    })
    document.querySelector('select').value = planId
    application = Application.start()
    application.register('set-plan-modal', SetPlanModalController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  async function act(trigger) {
    trigger()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  const submit = () => document.querySelector('form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  const remove = () => document.getElementById('remove').click()

  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve({ message: 'Done' }) })
  })

  afterEach(() => {
    application.stop()
    global.fetch = originalFetch
    document.head.innerHTML = ''
    document.body.innerHTML = ''
    jest.clearAllMocks()
  })

  test.each([
    ['submit', submit, 'http://localhost/plans/assign', 'POST'],
    ['remove', remove, '/plans/unassign', 'DELETE'],
  ])('%s sends the selected creatives and plan, then closes the modal', async (_name, trigger, url, method) => {
    await mount()

    await act(trigger)

    expect(global.fetch).toHaveBeenCalledWith(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-CSRF-Token': 'token-1' },
      body: JSON.stringify({ plan_id: '9', creative_ids: '3,5' }),
    })
    expect(alertDialog).toHaveBeenCalledWith('Done')
    expect(document.querySelector('[data-set-plan-modal-target="modal"]').style.display).toBe('none')
  })

  test.each([['submit', submit], ['remove', remove]])('%s asks for a creative when none is selected', async (_name, trigger) => {
    await mount({ checked: [] })

    await act(trigger)

    expect(alertDialog).toHaveBeenCalledWith('Select a creative')
    expect(global.fetch).not.toHaveBeenCalled()
  })

  test.each([['submit', submit], ['remove', remove]])('%s asks for a plan when none is chosen', async (_name, trigger) => {
    await mount({ planId: '' })

    await act(trigger)

    expect(alertDialog).toHaveBeenCalledWith('Select a plan')
    expect(global.fetch).not.toHaveBeenCalled()
  })
})
