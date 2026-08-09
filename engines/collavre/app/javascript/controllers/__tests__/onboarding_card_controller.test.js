/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import OnboardingCardController from '../onboarding_card_controller'

describe('OnboardingCardController', () => {
  let application

  beforeEach(async () => {
    window.CSS ||= {}
    window.CSS.escape ||= (value) => String(value)
    Element.prototype.scrollIntoView = jest.fn()
    document.body.innerHTML = `
      <div id="workspace" data-controller="onboarding-card" data-onboarding-card-workspace-value="true"></div>
    `
    application = Application.start()
    application.register('onboarding-card', OnboardingCardController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application.stop()
    window.history.replaceState({}, '', '/')
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('highlights the real progress toggle when it appears', async () => {
    application.stop()
    window.history.replaceState({}, '', '/creatives?id=1&onboarding_action=progress&onboarding_target_id=42')
    application = Application.start()
    application.register('onboarding-card', OnboardingCardController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    const row = document.createElement('creative-tree-row')
    row.setAttribute('creative-id', '42')
    row.innerHTML = '<button data-progress-toggle>0%</button>'
    document.body.appendChild(row)
    await new Promise((resolve) => setTimeout(resolve, 0))

    const toggle = row.querySelector('[data-progress-toggle]')
    expect(toggle.classList.contains('onboarding-progress-highlight')).toBe(true)
    expect(document.activeElement).toBe(toggle)
  })

  test('opens the existing inline editor flow for the tracked Creative', async () => {
    application.stop()
    window.history.replaceState({}, '', '/creatives?id=1&onboarding_action=edit&onboarding_target_id=77')
    const listener = jest.fn()
    document.addEventListener('creative-edit-click', listener)
    const row = document.createElement('creative-tree-row')
    row.setAttribute('creative-id', '77')
    row.innerHTML = '<div class="creative-tree"></div>'
    document.body.appendChild(row)
    application = Application.start()
    application.register('onboarding-card', OnboardingCardController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener.mock.calls[0][0].detail.treeElement).toBe(row.querySelector('.creative-tree'))
  })

  test('focuses chat and starts an agent mention without overwriting a draft', async () => {
    application.stop()
    window.history.replaceState({}, '', '/creatives?id=1&open_comments=true&onboarding_action=mention')
    const form = document.createElement('form')
    form.id = 'new-comment-form'
    form.innerHTML = '<textarea>draft</textarea>'
    document.body.appendChild(form)
    const input = jest.fn()
    form.querySelector('textarea').addEventListener('input', input)
    application = Application.start()
    application.register('onboarding-card', OnboardingCardController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    const textarea = form.querySelector('textarea')
    expect(textarea.value).toBe('@draft')
    expect(textarea.selectionStart).toBe(1)
    expect(document.activeElement).toBe(textarea)
    expect(input).toHaveBeenCalledTimes(1)
  })
})
