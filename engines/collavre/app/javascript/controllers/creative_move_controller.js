import { Controller } from '@hotwired/stimulus'
import { executeMoveCommand } from '../creatives/drag_drop/move_command'
import { invalidateCreativeTree } from '../lib/creative_tree_invalidation'

// Both trees expose native buttons with data-creative-move-id. The picker browses
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
    this.trigger = button
    const id = button.dataset.creativeMoveId
    this.triggerId = id
    const selected = [...document.querySelectorAll('.select-creative-checkbox:checked')].map(el => el.value)
    this.ids = selected.includes(id) ? [...new Set(selected)] : [id]
    this.canMove = ![...document.querySelectorAll('[data-creative-move-writable="false"]')]
      .some(el => this.ids.includes(el.dataset.creativeMoveId))
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
    // A refresh replaces the trigger rather than moving it, so recover the
    // button for the same creative first: falling straight through to the
    // first button in the document would drop the user at the top of a tree
    // they did not act on. The creative can also be gone from both trees --
    // moved under a collapsed branch -- and only then is any button better
    // than none.
    const buttons = [...document.querySelectorAll('[data-creative-move-id]')]
    const sameCreative = buttons.find(el => el.dataset.creativeMoveId === this.triggerId)
    ;(sameCreative || buttons[0])?.focus()
  }
}
