/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import OnboardingCardController from '../onboarding_card_controller'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('OnboardingCardController', () => {
  let application
  let controller
  let fetchMock
  let state

  beforeEach(async () => {
    state = {
      current_step: 'welcome',
      instruction: 'Select the practice Creative.',
      completion: 'ui',
      completed_steps: ['done'],
      anchor: 'tree.node',
    }
    fetchMock = jest.fn((url) => {
      if (url === '/onboarding') return Promise.resolve(jsonResponse(state))
      return Promise.resolve(jsonResponse({}))
    })
    global.fetch = fetchMock
    document.body.innerHTML = cardMarkup()
    application = Application.start()
    application.register('onboarding-card', OnboardingCardController)
    await flush()
    controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="onboarding-card"]'),
      'onboarding-card'
    )
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    delete global.fetch
    delete window.Turbo
    jest.restoreAllMocks()
  })

  test('renders the current UI step and highlights its registered anchor', () => {
    expect(controller.instructionTarget.textContent).toBe('Select the practice Creative.')
    expect(controller.nextTarget.hidden).toBe(false)
    expect(controller.finishTarget.hidden).toBe(true)
    expect(controller.currentStepValue).toBe('welcome')
    expect(controller.stepTargets[0].classList.contains('is-current')).toBe(true)
    expect(controller.stepTargets[1].classList.contains('is-complete')).toBe(true)
    expect(document.querySelector('[data-guide-anchor="tree.node"]').classList.contains('guide-anchor-highlight')).toBe(true)
  })

  test('keeps the next action hidden for server-driven steps', async () => {
    state = {
      current_step: 'comment',
      instruction: 'Write a comment.',
      completion: 'server',
      completed_steps: [],
      anchor: 'chat.composer',
    }

    await controller.refresh()

    expect(controller.instructionTarget.textContent).toBe('Write a comment.')
    expect(controller.nextTarget.hidden).toBe(true)
    expect(document.querySelector('[data-guide-anchor="tree.node"]').classList.contains('guide-anchor-highlight')).toBe(false)
    expect(document.querySelector('[data-guide-anchor="chat.composer"]').classList.contains('guide-anchor-highlight')).toBe(true)
  })

  test('highlights the keyed actionable anchor when a scenario step targets one Creative', async () => {
    state = {
      current_step: 'progress',
      instruction: 'Check the practice item.',
      completion: 'progress_changed',
      completed_steps: ['welcome'],
      anchor: 'tree.progress',
      anchor_key: 2,
    }
    document.body.insertAdjacentHTML('beforeend', `
      <button data-guide-anchor="tree.progress" data-guide-anchor-key="1"></button>
      <button data-guide-anchor="tree.progress" data-guide-anchor-key="2"></button>
    `)

    await controller.refresh()

    expect(document.querySelector('[data-guide-anchor-key="1"]').classList.contains('guide-anchor-highlight')).toBe(false)
    expect(document.querySelector('[data-guide-anchor-key="2"]').classList.contains('guide-anchor-highlight')).toBe(true)
  })

  test('navigates to the practice tree before highlighting a progress step', async () => {
    const visit = jest.fn()
    window.Turbo = { visit }
    state = {
      current_step: 'progress',
      instruction: 'Check the practice item.',
      completion: 'progress_changed',
      completed_steps: ['welcome'],
      anchor: 'tree.progress',
      anchor_key: 2,
      navigation_path: '/creatives?id=1',
    }

    await controller.refresh()

    expect(visit).toHaveBeenCalledWith('/creatives?id=1')
    expect(visit).toHaveBeenCalledTimes(1)
  })

  test('renders the completed state and ignores incomplete or failed responses', async () => {
    state = { complete: true, instruction: 'All done.' }
    await controller.refresh()

    expect(controller.instructionTarget.textContent).toBe('All done.')
    expect(controller.nextTarget.hidden).toBe(true)
    expect(controller.finishTarget.hidden).toBe(false)

    state = {}
    await controller.refresh()
    expect(controller.instructionTarget.textContent).toBe('All done.')

    fetchMock.mockImplementationOnce(() => Promise.resolve({ ok: false }))
    await controller.refresh()
    expect(controller.instructionTarget.textContent).toBe('All done.')
  })

  test('advances through the server endpoint then refreshes the state', async () => {
    await controller.advance()

    expect(fetchMock).toHaveBeenCalledWith('/onboarding/advance', expect.objectContaining({
      method: 'POST',
      credentials: 'same-origin',
    }))
    expect(fetchMock.mock.calls.at(-1)[0]).toBe('/onboarding')
  })

  test('completes through Turbo when a redirect is returned', async () => {
    const visit = jest.fn()
    window.Turbo = { visit }
    fetchMock.mockImplementationOnce(() => Promise.resolve(jsonResponse({ redirect_url: '/features' })))

    await controller.complete()

    expect(fetchMock).toHaveBeenLastCalledWith('/onboarding/complete', expect.objectContaining({ method: 'POST' }))
    expect(visit).toHaveBeenCalledWith('/features')
    expect(visit).toHaveBeenCalledTimes(1)
  })

  test('cleans up its polling timer and anchor highlight when disconnected', () => {
    expect(document.querySelector('[data-guide-anchor="tree.node"]').classList.contains('guide-anchor-highlight')).toBe(true)

    controller.disconnect()

    expect(document.querySelector('[data-guide-anchor="tree.node"]').classList.contains('guide-anchor-highlight')).toBe(false)
  })
})

function jsonResponse(data) {
  return { ok: true, headers: new Headers(), json: async () => data }
}

function cardMarkup() {
  return `
    <div data-controller="onboarding-card"
         data-onboarding-card-state-url-value="/onboarding"
         data-onboarding-card-advance-url-value="/onboarding/advance"
         data-onboarding-card-complete-url-value="/onboarding/complete">
      <p data-onboarding-card-target="instruction"></p>
      <div data-onboarding-card-target="step" data-step-key="welcome"></div>
      <div data-onboarding-card-target="step" data-step-key="done"></div>
      <button data-onboarding-card-target="next"></button>
      <span data-onboarding-card-target="finish"></span>
    </div>
    <button data-guide-anchor="tree.node" class="guide-anchor-highlight"></button>
    <textarea data-guide-anchor="chat.composer"></textarea>
  `
}
