import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../lib/api/csrf_fetch'
import { alertDialog, confirmDialog } from '../lib/utils/dialog'

export default class extends Controller {
  async revert(event) {
    const button = event.currentTarget
    if (!await confirmDialog(button.dataset.confirm, { danger: true })) return

    button.disabled = true
    try {
      let response = await this.request(button.dataset.url, {}, button.dataset.mode)
      let body = await response.json()
      if (response.status === 409) {
        response = await this.resolveConflicts(button, body.conflicts)
        body = await response.json()
      }
      if (!response.ok) throw new Error(body.message)
      if (body.status === 'partial') await alertDialog(body.message)

      this.dispatch('applied', { detail: body })
      this.listController?.loadInitialComments()
      window.dispatchEvent(new CustomEvent('collavre:creative-drop-complete'))
    } catch (error) {
      await alertDialog(error.message)
      button.disabled = false
    }
  }

  async resolveConflicts(button, conflicts) {
    const resolutions = {}
    for (const conflict of conflicts) {
      const force = await confirmDialog(
        button.dataset.conflict.replace('%{id}', conflict.creative_id),
        { danger: true, confirmText: button.dataset.force, cancelText: button.dataset.skip },
      )
      resolutions[conflict.creative_id] = force ? 'force' : 'skip'
    }
    return this.request(button.dataset.url, resolutions, button.dataset.mode)
  }

  request(url, resolutions = {}, mode = 'revert') {
    return csrfFetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ resolutions, mode }),
    })
  }

  get listController() {
    return this.application.getControllerForElementAndIdentifier(
      this.element.closest('[data-controller~="comments--list"]'),
      'comments--list',
    )
  }
}
