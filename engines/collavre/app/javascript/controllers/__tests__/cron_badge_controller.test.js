/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const confirmDialog = jest.fn()
const alertDialog = jest.fn()

jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  confirmDialog,
  alertDialog,
}))

const { default: CronBadgeController } = await import('../cron_badge_controller')

describe('CronBadgeController', () => {
  let application
  let element
  let controller

  beforeEach(async () => {
    document.head.innerHTML = '<meta name="csrf-token" content="token">'
    document.body.innerHTML = `
      <span data-controller="cron-badge"
            data-cron-badge-delete-confirm-value="Delete it?"
            data-cron-badge-delete-error-value="Delete failed"
            data-cron-badge-count-one-value="__count__ scheduled job"
            data-cron-badge-count-other-value="__count__ scheduled jobs">
        <button data-cron-badge-target="badge" title="2 scheduled jobs" aria-label="2 scheduled jobs">
          <span data-cron-badge-target="count">2</span>
        </button>
        <span data-cron-badge-target="task">
          <button data-action="click->cron-badge#destroy" data-cron-delete-url="/creatives/42/crons/one">Delete</button>
        </span>
        <span data-cron-badge-target="task">
          <button data-action="click->cron-badge#destroy" data-cron-delete-url="/creatives/42/crons/two">Delete</button>
        </span>
      </span>
    `
    element = document.querySelector('[data-controller="cron-badge"]')
    application = Application.start()
    application.register('cron-badge', CronBadgeController)
    await new Promise(resolve => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(element, 'cron-badge')
    confirmDialog.mockReset()
    alertDialog.mockReset()
    global.fetch = jest.fn()
  })

  afterEach(() => {
    application.stop()
    document.head.innerHTML = ''
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('deletes a task and updates the count', async () => {
    confirmDialog.mockResolvedValue(true)
    fetch.mockResolvedValue({ ok: true, status: 204 })

    element.querySelector('[data-cron-delete-url$="/one"]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(confirmDialog).toHaveBeenCalledWith('Delete it?', { danger: true })
    expect(fetch).toHaveBeenCalledWith('/creatives/42/crons/one', {
      method: 'DELETE',
      headers: { 'X-CSRF-Token': 'token' },
    })
    expect(controller.taskTargets).toHaveLength(1)
    expect(controller.countTarget.textContent).toBe('1')
    expect(controller.badgeTarget.title).toBe('1 scheduled job')
    expect(controller.badgeTarget.getAttribute('aria-label')).toBe('1 scheduled job')
  })

  test('removes the badge after deleting its last task', async () => {
    element.querySelectorAll('[data-cron-badge-target="task"]')[1].remove()
    confirmDialog.mockResolvedValue(true)
    fetch.mockResolvedValue({ ok: true, status: 204 })

    element.querySelector('[data-cron-delete-url$="/one"]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(document.body.contains(element)).toBe(false)
  })

  test('refreshes creative trees after deleting a task', async () => {
    const refetch = jest.fn()
    const invalidate = jest.fn()
    document.addEventListener('creative-sync:refetch', refetch)
    document.addEventListener('workspace-tree:invalidate', invalidate)
    confirmDialog.mockResolvedValue(true)
    fetch.mockResolvedValue({ ok: true, status: 204 })

    element.querySelector('[data-cron-delete-url$="/one"]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(refetch).toHaveBeenCalledTimes(1)
    expect(invalidate).toHaveBeenCalledTimes(1)
    document.removeEventListener('creative-sync:refetch', refetch)
    document.removeEventListener('workspace-tree:invalidate', invalidate)
  })

  test('does not request deletion when confirmation is cancelled', async () => {
    confirmDialog.mockResolvedValue(false)

    element.querySelector('[data-cron-delete-url$="/one"]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(fetch).not.toHaveBeenCalled()
    expect(controller.taskTargets).toHaveLength(2)
  })

  test('reports a failed deletion and restores the button', async () => {
    confirmDialog.mockResolvedValue(true)
    fetch.mockResolvedValue({ ok: false, status: 500 })
    alertDialog.mockResolvedValue(undefined)
    const button = element.querySelector('[data-cron-delete-url$="/one"]')

    button.click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(alertDialog).toHaveBeenCalledWith('Delete failed')
    expect(button.disabled).toBe(false)
    expect(controller.taskTargets).toHaveLength(2)
  })

  test('stops popup clicks from selecting the parent topic', () => {
    const event = { stopPropagation: jest.fn() }

    controller.stopPropagation(event)

    expect(event.stopPropagation).toHaveBeenCalled()
  })

})
