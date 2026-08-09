/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

describe('CommentsListController onboarding approval refresh', () => {
  const buildController = (formController = { _refreshOnboardingItems: jest.fn() }) => {
    const controller = Object.create(CommentsListController.prototype)
    controller.creativeId = '42'
    controller.currentTopicId = null
    controller.reloadCreativeChildren = jest.fn().mockResolvedValue()
    Object.defineProperty(controller, 'application', {
      value: { getControllerForElementAndIdentifier: jest.fn().mockReturnValue(formController) },
    })
    Object.defineProperty(controller, 'element', { value: document.createElement('div') })
    return { controller, formController }
  }

  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="test-token">'
    document.body.innerHTML = `
      <div id="comment_7"></div>
      <button data-comment-id="7"></button>
    `
  })

  afterEach(() => {
    jest.restoreAllMocks()
  })

  test('reloads the created practice row and refreshes the card and root', async () => {
    const { controller, formController } = buildController()
    const headers = new Map([
      ['X-Onboarding-Card-Id', '42'],
      ['X-Onboarding-Root-Id', '84'],
      ['X-Onboarding-Created-Creative-Id', '126'],
    ])
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      text: jest.fn().mockResolvedValue('<div id="comment_7">Approved</div>'),
      headers: { get: (name) => headers.get(name) },
    })

    await controller.decideComment(document.querySelector('button'), 'approve')

    expect(controller.reloadCreativeChildren).toHaveBeenCalledWith('42')
    expect(formController._refreshOnboardingItems).toHaveBeenCalledWith('42', '84')
    expect(document.getElementById('comment_7').textContent).toBe('Approved')
  })

  test('refreshes an updated onboarding card without reloading children', async () => {
    const { controller, formController } = buildController()
    const headers = new Map([
      ['X-Onboarding-Card-Id', '42'],
      ['X-Onboarding-Root-Id', '84'],
    ])
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      text: jest.fn().mockResolvedValue('<div id="comment_7">Approved</div>'),
      headers: { get: (name) => headers.get(name) },
    })

    await controller.decideComment(document.querySelector('button'), 'approve')

    expect(controller.reloadCreativeChildren).not.toHaveBeenCalled()
    expect(formController._refreshOnboardingItems).toHaveBeenCalledWith('42', '84')
  })

  test('reports an approval error and re-enables the button', async () => {
    const { controller } = buildController()
    const button = document.querySelector('button')
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      json: jest.fn().mockResolvedValue({ error: 'Approval failed' }),
    })

    await controller.decideComment(button, 'approve')

    expect(button.disabled).toBe(false)
    expect(document.body.textContent).toContain('Approval failed')
  })
})
