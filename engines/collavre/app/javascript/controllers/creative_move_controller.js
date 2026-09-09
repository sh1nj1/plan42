import { Controller } from '@hotwired/stimulus'
import { executeMoveCommand } from '../creatives/drag_drop/move_command'
import { invalidateCreativeTree } from '../lib/creative_tree_invalidation'

// The header overflow menu opens the move dialog. The picker browses
// server data, so destinations do not have to exist in either rendered tree.
export default class extends Controller {
  static targets = ['dialog', 'destination', 'direction', 'mode', 'confirm', 'status', 'announcement']
  static values = { messages: Object }

  connect() {
    this.disconnected = false
    this.openFromClick = this.openFromClick.bind(this)
    document.addEventListener('click', this.openFromClick)
  }

  disconnect() {
    document.removeEventListener('click', this.openFromClick)
    this.focusObserver?.disconnect()
    this.disconnected = true
    this.dialogTarget.close()
  }

  openFromClick(event) {
    const button = event.target.closest('[data-creative-move-id]')
    if (!button || this.busy || this.picking || this.dialogTarget.open) return
    event.preventDefault()
    this.focusObserver?.disconnect()
    this.trigger = button.closest('[data-controller="popup-menu"]')?.querySelector('[data-popup-menu-target="button"]') || button
    const id = button.dataset.creativeMoveId
    this.triggerId = id
    const selectedRows = [...document.querySelectorAll('.select-creative-checkbox:checked')]
    // Lit reflects archived as a Boolean attribute, including archived="".
    if (selectedRows.some(el => el.closest('creative-tree-row')?.hasAttribute('archived'))) {
      this.ids = []
      this.targetId = null
      this.announcementTarget.textContent = this.messagesValue.archived
      window.alert(this.messagesValue.archived)
      this.restoreFocus()
      return
    }
    const selected = selectedRows.map(el => el.value)
    this.ids = selected.length ? [...new Set(selected)] : id ? [id] : []
    if (!this.ids.length) {
      this.startSelection()
      return
    }
    this.canMove = selected.length
      ? selectedRows.every(el => el.closest('creative-tree-row')?.hasAttribute('can-write') === true)
      : button.dataset.creativeMoveWritable === 'true'
    this.targetId = null
    this.directionTarget.value = 'child'
    this.modeTarget.querySelector('option[value="move"]').disabled = !this.canMove
    this.modeTarget.value = this.canMove ? 'move' : 'link'
    this.destinationTarget.textContent = this.messagesValue.choose
    this.confirmTarget.disabled = true
    this.statusTarget.textContent = ''
    this.announcementTarget.textContent = ''
    this.dialogTarget.showModal()
    this.destinationTarget.focus()
  }

  startSelection() {
    const checkbox = document.querySelector('.select-creative-checkbox')
    if (checkbox) {
      const select = document.getElementById('select-creative-btn')
      if (select?.getAttribute('aria-pressed') !== 'true') select?.click()
      checkbox.focus()
      return
    }
    // The selection toggle also lives in the closed overflow menu. Wait on
    // its visible launcher until CSR supplies a source, without stealing focus.
    this.restoreFocus()
    this.focusObserver = new MutationObserver(() => {
      if (document.activeElement !== this.trigger || !this.trigger.isConnected) {
        this.focusObserver.disconnect()
      } else if (document.querySelector('.select-creative-checkbox')) {
        this.focusObserver.disconnect()
        this.startSelection()
      }
    })
    this.focusObserver.observe(document.body, { childList: true, subtree: true })
  }

  chooseDestination() {
    const modal = document.getElementById('link-creative-modal')
    const picker = modal && this.application.getControllerForElementAndIdentifier(modal, 'link-creative')
    if (!picker) {
      this.statusTarget.textContent = this.messagesValue.failed
      return
    }
    const rect = this.destinationTarget.getBoundingClientRect()
    this.picking = true
    this.dialogTarget.close()
    picker.open(rect, item => {
      this.targetId = String(item.id)
      this.destinationTarget.textContent = item.label
      const invalid = this.ids.includes(this.targetId)
      this.confirmTarget.disabled = invalid
      this.statusTarget.textContent = invalid ? this.messagesValue.invalid : ''
    }, () => {
      this.picking = false
      if (this.disconnected) return
      this.dialogTarget.showModal()
      this.destinationTarget.focus()
    }, { allowCreate: false, selectOrigin: false })
  }

  cancel(event) {
    event?.preventDefault()
    if (this.busy) return
    this.dialogTarget.close()
    this.announcementTarget.textContent = this.messagesValue.cancelled
    this.restoreFocus()
  }

  async submit(event) {
    event.preventDefault()
    if (this.busy || !this.targetId || this.ids.includes(this.targetId)) return
    if (!this.canMove && this.modeTarget.value === 'move') return
    this.busy = true
    this.setDisabled(true)
    this.statusTarget.textContent = this.messagesValue.moving
    try {
      const result = await executeMoveCommand({
        ids: this.ids, targetId: this.targetId,
        direction: this.directionTarget.value, mode: this.modeTarget.value
      })
      if (result.succeededIds.length) invalidateCreativeTree({
        direction: this.directionTarget.value, targetCreativeId: this.targetId
      })
      if (this.disconnected) return
      if (result.ok) {
        this.dialogTarget.close()
        this.announcementTarget.textContent = this.messagesValue.complete
        this.restoreFocusAfterRefresh()
      } else {
        // Retry only failures: link operations may have partially succeeded.
        this.ids = result.failedIds
        this.statusTarget.textContent = this.messagesValue[result.status === 'partial' ? 'partial' : 'failed']
      }
    } catch {
      if (!this.disconnected) this.statusTarget.textContent = this.messagesValue.failed
    } finally {
      this.busy = false
      if (!this.disconnected) this.setDisabled(false)
    }
  }

  setDisabled(disabled) {
    this.dialogTarget.querySelectorAll('button, select').forEach(el => { el.disabled = disabled })
  }

  restoreFocusAfterRefresh() {
    this.restoreFocus()
    this.focusObserver?.disconnect()
    // Tree refreshes replace the trigger asynchronously. Recover only if the
    // user has not already focused another control while the request finishes.
    this.focusObserver = new MutationObserver(() => {
      const active = document.activeElement
      if (active !== this.trigger && active !== document.body) {
        this.focusObserver.disconnect()
      } else if (!this.trigger?.isConnected) {
        this.restoreFocus()
        this.focusObserver.disconnect()
      }
    })
    this.focusObserver.observe(document.body, { childList: true, subtree: true })
  }

  restoreFocus() {
    if (this.trigger?.isConnected) return this.trigger.focus()
    // Navigation can replace the entire header while the command completes.
    // Focus the visible overflow toggle, never its now-hidden menu item.
    const buttons = [...document.querySelectorAll('[data-creative-move-id]')].map(button =>
      button.closest('[data-controller="popup-menu"]')?.querySelector('[data-popup-menu-target="button"]') || button)
    const sameCreative = buttons.find(el => el.dataset.creativeMoveId === this.triggerId)
    ;(sameCreative || buttons[0])?.focus()
  }
}
