import { Controller } from '@hotwired/stimulus'
import { alertDialog, confirmDialog } from '../lib/utils/dialog'
import { invalidateCreativeTree } from '../lib/creative_tree_invalidation'
import csrfFetch, { refreshCsrfToken } from '../lib/api/csrf_fetch'

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
    const input = button.closest('[data-cron-badge-target="task"]')
      ?.querySelector('[data-cron-badge-target="messageInput"]')
    if (!input) return

    button.disabled = true
    input.disabled = true

    try {
      const response = await this.updateCron(button.dataset.cronUpdateUrl, input.value)
      if (!response.ok) throw new Error(`Cron update failed (${response.status})`)

      input.dataset.cronSavedMessage = input.value
      invalidateCreativeTree()
    } catch (error) {
      console.error(error)
      await alertDialog(this.updateErrorValue)
    } finally {
      button.disabled = false
      input.disabled = false
    }
  }

  async destroy(event) {
    event.preventDefault()
    event.stopPropagation()
    const button = event.currentTarget

    if (!(await confirmDialog(this.deleteConfirmValue, { danger: true }))) return

    button.disabled = true

    try {
      const response = await this.deleteCron(button.dataset.cronDeleteUrl)
      if (!response.ok) throw new Error(`Cron delete failed (${response.status})`)

      button.closest('[data-cron-badge-target="task"]')?.remove()
      this.refreshCount()
      invalidateCreativeTree()
    } catch (error) {
      console.error(error)
      button.disabled = false
      await alertDialog(this.deleteErrorValue)
    }
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

  refreshCount() {
    const count = this.taskTargets.length
    if (count === 0) {
      this.element.remove()
      return
    }

    this.countTarget.textContent = String(count)
    const template = count === 1 ? this.countOneValue : this.countOtherValue
    const label = template.replace('__count__', String(count))
    this.badgeTarget.title = label
    this.badgeTarget.setAttribute('aria-label', label)
  }
}
