import { Controller } from '@hotwired/stimulus'
import { alertDialog, confirmDialog } from '../lib/utils/dialog'
import { invalidateCreativeTree } from '../lib/creative_tree_invalidation'

export default class extends Controller {
  static targets = ['badge', 'count', 'task']
  static values = {
    countOne: String,
    countOther: String,
    deleteConfirm: String,
    deleteError: String,
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  async destroy(event) {
    event.preventDefault()
    event.stopPropagation()
    const button = event.currentTarget

    if (!(await confirmDialog(this.deleteConfirmValue, { danger: true }))) return

    button.disabled = true

    try {
      const response = await fetch(button.dataset.cronDeleteUrl, {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' },
      })
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
