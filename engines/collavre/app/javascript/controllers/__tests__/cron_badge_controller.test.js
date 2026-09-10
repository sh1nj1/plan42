/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const confirmDialog = jest.fn()
const alertDialog = jest.fn()
const csrfFetch = jest.fn()
const refreshCsrfToken = jest.fn()

jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  confirmDialog,
  alertDialog,
}))
jest.unstable_mockModule('../../lib/api/csrf_fetch', () => ({
  default: csrfFetch,
  refreshCsrfToken,
}))

const { default: CronBadgeController } = await import('../cron_badge_controller')

function response({ ok, status, body = '' }) {
  return {
    ok,
    status,
    clone: () => ({ text: async () => body }),
  }
}

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
            data-cron-badge-update-error-value="Update failed"
            data-cron-badge-count-one-value="__count__ scheduled job"
            data-cron-badge-count-other-value="__count__ scheduled jobs">
        <button data-cron-badge-target="badge" title="2 scheduled jobs" aria-label="2 scheduled jobs">
          <span data-cron-badge-target="count">2</span>
        </button>
        <span data-cron-badge-target="task">
          <textarea data-cron-badge-target="messageInput">First message</textarea>
          <button data-action="click->cron-badge#saveMessage" data-cron-update-url="/creatives/42/crons/one">Save</button>
          <button data-action="click->cron-badge#destroy" data-cron-delete-url="/creatives/42/crons/one">Delete</button>
        </span>
        <span data-cron-badge-target="task">
          <textarea data-cron-badge-target="messageInput">Second message</textarea>
          <button data-action="click->cron-badge#saveMessage" data-cron-update-url="/creatives/42/crons/two">Save</button>
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
    csrfFetch.mockReset()
    refreshCsrfToken.mockReset()
  })

  afterEach(() => {
    application.stop()
    document.head.innerHTML = ''
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('deletes a task and updates the count', async () => {
    confirmDialog.mockResolvedValue(true)
    csrfFetch.mockResolvedValue({ ok: true, status: 204 })

    element.querySelector('[data-cron-delete-url$="/one"]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(confirmDialog).toHaveBeenCalledWith('Delete it?', { danger: true })
    expect(csrfFetch).toHaveBeenCalledWith('/creatives/42/crons/one', { method: 'DELETE' })
    expect(controller.taskTargets).toHaveLength(1)
    expect(controller.countTarget.textContent).toBe('1')
    expect(controller.badgeTarget.title).toBe('1 scheduled job')
    expect(controller.badgeTarget.getAttribute('aria-label')).toBe('1 scheduled job')
  })

  test('refreshes the plural count label', () => {
    controller.refreshCount()

    expect(controller.countTarget.textContent).toBe('2')
    expect(controller.badgeTarget.title).toBe('2 scheduled jobs')
    expect(controller.badgeTarget.getAttribute('aria-label')).toBe('2 scheduled jobs')
  })

  test('updates a task message and refreshes creative trees', async () => {
    const refetch = jest.fn()
    const invalidate = jest.fn()
    document.addEventListener('creative-sync:refetch', refetch)
    document.addEventListener('workspace-tree:invalidate', invalidate)
    csrfFetch.mockResolvedValue({ ok: true, status: 200 })

    const task = element.querySelector('[data-cron-badge-target="task"]')
    const input = task.querySelector('[data-cron-badge-target="messageInput"]')
    const button = task.querySelector('[data-cron-update-url]')
    input.value = 'Updated message'
    button.click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(csrfFetch).toHaveBeenCalledWith('/creatives/42/crons/one', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: 'Updated message' }),
    })
    expect(refetch).toHaveBeenCalledTimes(1)
    expect(invalidate).toHaveBeenCalledTimes(1)
    expect(input.dataset.cronSavedMessage).toBe('Updated message')
    expect(button.disabled).toBe(false)
    expect(input.disabled).toBe(false)
    document.removeEventListener('creative-sync:refetch', refetch)
    document.removeEventListener('workspace-tree:invalidate', invalidate)
  })

  test('ignores a message update when its input is missing', async () => {
    const task = element.querySelector('[data-cron-badge-target="task"]')
    task.querySelector('[data-cron-badge-target="messageInput"]').remove()

    task.querySelector('[data-cron-update-url]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(csrfFetch).not.toHaveBeenCalled()
  })

  test('reports a failed message update and restores the controls', async () => {
    csrfFetch.mockResolvedValue({ ok: false, status: 500 })
    alertDialog.mockResolvedValue(undefined)
    const task = element.querySelector('[data-cron-badge-target="task"]')
    const input = task.querySelector('[data-cron-badge-target="messageInput"]')
    const button = task.querySelector('[data-cron-update-url]')

    button.click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(alertDialog).toHaveBeenCalledWith('Update failed')
    expect(button.disabled).toBe(false)
    expect(input.disabled).toBe(false)
  })

  test('keeps replacement controls disabled until an in-flight update settles', async () => {
    let resolveUpdate
    csrfFetch.mockReturnValue(new Promise(resolve => { resolveUpdate = resolve }))
    alertDialog.mockResolvedValue(undefined)
    const task = element.querySelector('[data-cron-badge-target="task"]')
    const button = task.querySelector('[data-cron-update-url]')

    button.click()
    const replacement = element.cloneNode(true)
    element.replaceWith(replacement)
    const replacementTask = replacement.querySelector('[data-cron-badge-target="task"]')

    expect(replacementTask.querySelector('textarea').disabled).toBe(true)
    expect(replacementTask.querySelector('[data-cron-update-url]').disabled).toBe(true)

    resolveUpdate({ ok: false, status: 500 })
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(replacementTask.hasAttribute('data-cron-save-operation')).toBe(false)
    expect(replacementTask.querySelector('textarea').disabled).toBe(false)
    expect(replacementTask.querySelector('[data-cron-update-url]').disabled).toBe(false)
  })

  test('refreshes the CSRF token and retries a message update after a payload-less 422 response', async () => {
    csrfFetch
      .mockResolvedValueOnce(response({ ok: false, status: 422 }))
      .mockResolvedValueOnce({ ok: true, status: 200 })

    element.querySelector('[data-cron-update-url]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(refreshCsrfToken).toHaveBeenCalledTimes(1)
    expect(csrfFetch).toHaveBeenCalledTimes(2)
  })

  test('does not retry a message update after a semantic 422 response', async () => {
    csrfFetch.mockResolvedValue(response({
      ok: false,
      status: 422,
      body: JSON.stringify({ error: 'Message cannot be blank' }),
    }))
    alertDialog.mockResolvedValue(undefined)

    element.querySelector('[data-cron-update-url]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(refreshCsrfToken).not.toHaveBeenCalled()
    expect(csrfFetch).toHaveBeenCalledTimes(1)
    expect(alertDialog).toHaveBeenCalledWith('Update failed')
  })

  test('removes the badge after deleting its last task', async () => {
    element.querySelectorAll('[data-cron-badge-target="task"]')[1].remove()
    confirmDialog.mockResolvedValue(true)
    csrfFetch.mockResolvedValue({ ok: true, status: 204 })

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
    csrfFetch.mockResolvedValue({ ok: true, status: 204 })

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

    expect(csrfFetch).not.toHaveBeenCalled()
    expect(controller.taskTargets).toHaveLength(2)
  })

  test('reports a failed deletion and restores the button', async () => {
    confirmDialog.mockResolvedValue(true)
    csrfFetch.mockResolvedValue({ ok: false, status: 500 })
    alertDialog.mockResolvedValue(undefined)
    const button = element.querySelector('[data-cron-delete-url$="/one"]')

    button.click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(alertDialog).toHaveBeenCalledWith('Delete failed')
    expect(button.disabled).toBe(false)
    expect(controller.taskTargets).toHaveLength(2)
  })

  test('refreshes the CSRF token and retries once after a payload-less 422 response', async () => {
    confirmDialog.mockResolvedValue(true)
    csrfFetch
      .mockResolvedValueOnce(response({ ok: false, status: 422 }))
      .mockResolvedValueOnce({ ok: true, status: 204 })

    element.querySelector('[data-cron-delete-url$="/one"]').click()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(refreshCsrfToken).toHaveBeenCalledTimes(1)
    expect(csrfFetch).toHaveBeenCalledTimes(2)
    expect(csrfFetch).toHaveBeenNthCalledWith(2, '/creatives/42/crons/one', { method: 'DELETE' })
    expect(controller.taskTargets).toHaveLength(1)
  })

  test('stops popup clicks from selecting the parent topic', () => {
    const event = { stopPropagation: jest.fn() }

    controller.stopPropagation(event)

    expect(event.stopPropagation).toHaveBeenCalled()
  })

})
