import { Controller } from '@hotwired/stimulus'
import { alertDialog, confirmDialog } from '../lib/utils/dialog'
import { invalidateCreativeTree } from '../lib/creative_tree_invalidation'
import csrfFetch, { refreshCsrfToken } from '../lib/api/csrf_fetch'

let cronOperationSequence = 0

export default class extends Controller {
  static targets = ['badge', 'count', 'task', 'messageInput']
  static values = {
    countOne: String,
    countOther: String,
    deleteConfirm: String,
    deleteError: String,
    updateError: String,
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  async saveMessage(event) {
    event.preventDefault()
    event.stopPropagation()
    const button = event.currentTarget
    const task = button.closest('[data-cron-badge-target="task"]')
    const input = task?.querySelector('[data-cron-badge-target="messageInput"]')
    if (!input) return

    const releaseTreeReload = this.holdCreativeTreeReload()
    const operationId = String(++cronOperationSequence)
    const message = input.value
    task.dataset.cronSaveOperation = operationId
    button.disabled = true
    input.disabled = true

    try {
      const response = await this.updateCron(button.dataset.cronUpdateUrl, message)
      if (!response.ok) throw new Error(`Cron update failed (${response.status})`)

      this.updateSavedMessage(task, operationId, message)
      invalidateCreativeTree()
    } catch (error) {
      console.error(error)
      await alertDialog(this.updateErrorValue)
    } finally {
      this.finishMessageSave(task, operationId)
      releaseTreeReload()
    }
  }

  holdCreativeTreeReload() {
    const tree = this.element.closest('[data-controller~="creatives--tree"]')
    const controller = tree && this.application.getControllerForElementAndIdentifier(
      tree,
      'creatives--tree'
    )
    if (typeof controller?.beginReloadHold !== 'function' ||
        typeof controller?.endReloadHold !== 'function') return () => {}

    controller.beginReloadHold()
    return () => controller.endReloadHold()
  }

  finishMessageSave(task, operationId) {
    this.messageSaveTasks(task, operationId).forEach(candidate => {
      delete candidate.dataset.cronSaveOperation
      const input = candidate.querySelector('[data-cron-badge-target="messageInput"]')
      const button = candidate.querySelector('[data-action~="click->cron-badge#saveMessage"]')
      if (input) input.disabled = false
      if (button) button.disabled = false
    })
  }

  updateSavedMessage(task, operationId, message) {
    this.messageSaveTasks(task, operationId).forEach(candidate => {
      const input = candidate.querySelector('[data-cron-badge-target="messageInput"]')
      if (input) input.dataset.cronSavedMessage = message
    })
  }

  messageSaveTasks(task, operationId) {
    const currentTask = document.querySelector(
      `[data-cron-save-operation="${operationId}"]`
    )
    return new Set([task, currentTask].filter(candidate => (
      candidate?.dataset.cronSaveOperation === operationId
    )))
  }

  async destroy(event) {
    event.preventDefault()
    event.stopPropagation()
    const button = event.currentTarget

    if (!(await confirmDialog(this.deleteConfirmValue, { danger: true }))) return

		const releaseTreeReload = this.holdCreativeTreeReload()
		const task = button.closest('[data-cron-badge-target="task"]')
		const operationId = String(++cronOperationSequence)
		task.dataset.cronDeleteOperation = operationId
		button.disabled = true

    try {
      const response = await this.deleteCron(button.dataset.cronDeleteUrl)
      if (!response.ok) throw new Error(`Cron delete failed (${response.status})`)

			this.deleteOperationTasks(task, operationId).forEach(candidate => {
				const badge = candidate.closest('[data-controller~="cron-badge"]')
				candidate.remove()
				this.refreshCount(badge)
			})
      invalidateCreativeTree()
    } catch (error) {
      console.error(error)
			this.finishCronDelete(task, operationId)
      await alertDialog(this.deleteErrorValue)
		} finally {
			releaseTreeReload()
    }
  }

	finishCronDelete(task, operationId) {
		this.deleteOperationTasks(task, operationId).forEach(candidate => {
			delete candidate.dataset.cronDeleteOperation
			candidate.querySelector('[data-action~="click->cron-badge#destroy"]').disabled = false
		})
	}

	deleteOperationTasks(task, operationId) {
		const currentTask = document.querySelector(
			`[data-cron-delete-operation="${operationId}"]`
		)
		return new Set([task, currentTask].filter(candidate => (
			candidate?.dataset.cronDeleteOperation === operationId
		)))
	}

  async deleteCron(url) {
    const options = { method: 'DELETE' }
    let response = await csrfFetch(url, options)
    if (!(await this.shouldRetryCsrf(response))) return response

    await refreshCsrfToken()
    response = await csrfFetch(url, options)
    return response
  }

  async updateCron(url, message) {
    const options = {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message }),
    }
    let response = await csrfFetch(url, options)
    if (!(await this.shouldRetryCsrf(response))) return response

    await refreshCsrfToken()
    response = await csrfFetch(url, options)
    return response
  }

  async shouldRetryCsrf(response) {
    if (response.status !== 422) return false

    const body = await response.clone().text()
    return body.trim() === ''
  }

  refreshCount(element = this.element) {
		const tasks = element.querySelectorAll('[data-cron-badge-target="task"]')
		const count = tasks.length
    if (count === 0) {
			element.remove()
      return
    }

		const countTarget = element.querySelector('[data-cron-badge-target="count"]')
		const badgeTarget = element.querySelector('[data-cron-badge-target="badge"]')
		countTarget.textContent = String(count)
    const template = count === 1 ? this.countOneValue : this.countOtherValue
    const label = template.replace('__count__', String(count))
		badgeTarget.title = label
		badgeTarget.setAttribute('aria-label', label)
  }
}
