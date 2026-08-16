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
    window.sessionStorage.clear()
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
    window.sessionStorage.clear()
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

  test('renders the inline edit control while explaining mobile editing', async () => {
    state = {
      current_step: 'editor',
      instruction: 'On mobile, swipe to edit.',
      instruction_before: 'On mobile, swipe to reveal the ',
      instruction_after: ' button.',
      instruction_control: { type: 'editor', label: 'Edit' },
      completion: 'description_changed',
      completed_steps: [],
      anchor: 'creative.editor',
    }

    await controller.refresh()

    expect(controller.instructionTarget.textContent).toBe('On mobile, swipe to reveal the Edit button.')
    expect(controller.instructionTarget.querySelector('button').textContent).toBe('Edit')
    expect(document.querySelector('[data-onboarding-card-target="chatIcon"]')).toBeNull()
  })

  test('renders the inline add control before an item is added', async () => {
    state = {
      current_step: 'progress',
      instruction: 'Add an item.',
      instruction_before: 'Use the ',
      instruction_after: ' button to add an item.',
      instruction_control: { type: 'progress', label: 'Add' },
      completion: 'progress_changed',
      completed_steps: [],
      anchor: 'tree.add',
    }

    await controller.refresh()

    expect(controller.instructionTarget.textContent).toBe('Use the Add button to add an item.')
    expect(controller.instructionTarget.querySelector('button').textContent).toBe('Add')
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

  test('opens the workspace tree drawer before highlighting its node', async () => {
    document.body.insertAdjacentHTML('beforeend', `
      <section class="creative-workspace-tree-region" data-controller="workspace-tree">
        <button data-workspace-tree-target="panelToggle" aria-expanded="false"></button>
      </section>
    `)

    await controller.refresh()

    const panel = document.querySelector('[data-controller="workspace-tree"]')
    expect(panel.classList.contains('is-open')).toBe(true)
    expect(panel.querySelector('button').getAttribute('aria-expanded')).toBe('true')
  })

  test('does not reopen the workspace tree drawer after the learner closes it across card reconnects', async () => {
    document.body.insertAdjacentHTML('beforeend', `
<section class="creative-workspace-tree-region" data-controller="workspace-tree">
  <button data-workspace-tree-target="panelToggle" aria-expanded="false"></button>
</section>
    `)

    await controller.refresh()

    const panel = document.querySelector('[data-controller="workspace-tree"]')
    const toggle = panel.querySelector('button')
    panel.classList.remove('is-open')
    toggle.setAttribute('aria-expanded', 'false')
    panel.dispatchEvent(new CustomEvent('workspace-tree:panel-closed', { bubbles: true }))

    controller.disconnect()
    controller.connect()
    await flush()

    expect(panel.classList.contains('is-open')).toBe(false)
    expect(toggle.getAttribute('aria-expanded')).toBe('false')
  })

  test('opens the workspace tree drawer for a reset onboarding session after a previous session was dismissed', async () => {
    document.body.insertAdjacentHTML('beforeend', `
<section class="creative-workspace-tree-region" data-controller="workspace-tree">
  <button data-workspace-tree-target="panelToggle" aria-expanded="false"></button>
</section>
    `)

    await controller.refresh()

    const panel = document.querySelector('[data-controller="workspace-tree"]')
    const toggle = panel.querySelector('button')
    panel.classList.remove('is-open')
    toggle.setAttribute('aria-expanded', 'false')
    panel.dispatchEvent(new CustomEvent('workspace-tree:panel-closed', { bubbles: true }))

    controller.element.dataset.onboardingCardSessionIdValue = 'reset-session'
    controller.disconnect()
    controller.connect()
    await flush()

    expect(panel.classList.contains('is-open')).toBe(true)
    expect(toggle.getAttribute('aria-expanded')).toBe('true')
  })

  test('serializes slow polling responses and refreshes again afterward', async () => {
    let resolveSlowResponse
    const slowResponse = new Promise((resolve) => { resolveSlowResponse = resolve })
    fetchMock.mockImplementationOnce(() => slowResponse)
    const firstRefresh = controller.refresh()
    const secondRefresh = controller.refresh()

    state = {
      current_step: 'comment',
      instruction: 'Write a comment.',
      completion: 'server',
      completed_steps: ['welcome'],
      anchor: 'chat.composer',
    }
    resolveSlowResponse(jsonResponse({
      current_step: 'progress',
      instruction: 'Check the practice item.',
      completion: 'progress_changed',
      completed_steps: ['welcome'],
      anchor: 'tree.progress',
    }))
    await Promise.all([firstRefresh, secondRefresh])
    await flush()

    expect(controller.instructionTarget.textContent).toBe('Write a comment.')
    expect(controller.currentStepValue).toBe('comment')
    expect(document.querySelector('[data-guide-anchor="chat.composer"]').classList.contains('guide-anchor-highlight')).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(3)
  })

  test('discards a slow response invalidated by an advance action', async () => {
    let resolveSlowResponse
    const slowResponse = new Promise((resolve) => { resolveSlowResponse = resolve })
    fetchMock.mockImplementationOnce(() => slowResponse)
    const slowRefresh = controller.refresh()

    state = {
      current_step: 'comment',
      instruction: 'Write a comment.',
      completion: 'server',
      completed_steps: ['welcome'],
      anchor: 'chat.composer',
    }
    await controller.advance()
    resolveSlowResponse(jsonResponse({
      current_step: 'progress',
      instruction: 'Check the practice item.',
      completion: 'progress_changed',
      completed_steps: ['welcome'],
      anchor: 'tree.progress',
    }))
    await slowRefresh
    await flush()

    expect(controller.instructionTarget.textContent).toBe('Write a comment.')
    expect(controller.currentStepValue).toBe('comment')
    expect(document.querySelector('[data-guide-anchor="chat.composer"]').classList.contains('guide-anchor-highlight')).toBe(true)
  })

  test('renders the completed state and ignores incomplete or failed responses', async () => {
    state = { complete: true, instruction: 'All done.', completed_steps: ['welcome', 'done'] }
    await controller.refresh()

    expect(controller.instructionTarget.textContent).toBe('All done.')
    expect(controller.nextTarget.hidden).toBe(true)
    expect(controller.finishTarget.hidden).toBe(false)
    expect(controller.currentStepValue).toBe('')
    expect(controller.stepTargets.every((step) => !step.classList.contains('is-current'))).toBe(true)
    expect(controller.stepTargets.every((step) => step.classList.contains('is-complete'))).toBe(true)
    expect(document.querySelector('[data-guide-anchor="tree.node"]').classList.contains('guide-anchor-highlight')).toBe(false)

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
      headers: expect.any(Headers),
    }))
    const request = fetchMock.mock.calls.find(([url]) => url === '/onboarding/advance')[1]
    expect(request.headers.get('Content-Type')).toBe('application/json')
    expect(request.body).toBe(JSON.stringify({ session_id: 'initial-session' }))
    expect(fetchMock.mock.calls.at(-1)[0]).toBe('/onboarding')
  })

  test('rebinds actions to a replacement session returned by polling', async () => {
    state = {
      session_id: 'replacement-session',
      current_step: 'welcome',
      instruction: 'Select the replacement Creative.',
      completion: 'ui',
      completed_steps: [],
      anchor: 'tree.node',
    }

    await controller.refresh()
    await controller.advance()

    expect(controller.sessionIdValue).toBe('replacement-session')
    const request = fetchMock.mock.calls.find(([url]) => url === '/onboarding/advance')[1]
    expect(request.body).toBe(JSON.stringify({ session_id: 'replacement-session' }))
  })

  test('removes the stale card when its onboarding session disappears', async () => {
    state = { current_step: null }

    await controller.refresh()

    expect(controller.element.isConnected).toBe(false)
    expect(document.querySelector('[data-guide-anchor="tree.node"]').classList.contains('guide-anchor-highlight')).toBe(false)
  })

  test('returns home after completing the onboarding', async () => {
    const visit = jest.fn()
    window.Turbo = { visit }
    fetchMock.mockImplementationOnce(() => Promise.resolve(jsonResponse({ success: true, redirect_path: '/' })))

    await controller.complete()

    expect(fetchMock).toHaveBeenLastCalledWith('/onboarding/complete', expect.objectContaining({
      method: 'POST',
      body: JSON.stringify({ session_id: 'initial-session' }),
    }))
    expect(controller.element.isConnected).toBe(true)
    expect(visit).toHaveBeenCalledWith('/')
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
         data-onboarding-card-complete-url-value="/onboarding/complete"
         data-onboarding-card-session-id-value="initial-session">
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
