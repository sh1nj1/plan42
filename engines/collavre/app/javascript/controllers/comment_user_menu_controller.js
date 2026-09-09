import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['status', 'statusLabel']
  static values = {
    userId: Number,
    userName: String,
  }

  connect() {
    this.popupElement = this.element.closest('[data-controller~="comments--presence"]')
    this.handlePresenceChanged = this.handlePresenceChanged.bind(this)
    this.popupElement?.addEventListener('comments--presence:changed', this.handlePresenceChanged)
    this.syncPresence()
  }

  disconnect() {
    this.popupElement?.removeEventListener('comments--presence:changed', this.handlePresenceChanged)
  }

  mention() {
    const mentionMenu = this.application.getControllerForElementAndIdentifier(
      this.popupElement,
      'comments--mention-menu'
    )
    if (!mentionMenu) return

    mentionMenu.insertMention({ id: this.userIdValue, name: this.userNameValue })
    mentionMenu.textareaTarget?.focus()
  }

  handlePresenceChanged(event) {
    this.updatePresence(event.detail?.presentIds || [])
  }

  syncPresence() {
    this.updatePresence(this.presenceController?.currentPresentIds || [])
  }

  get presenceController() {
    return this.application.getControllerForElementAndIdentifier(this.popupElement, 'comments--presence')
  }

  updatePresence(presentIds) {
    if (!this.hasStatusTarget || !this.hasStatusLabelTarget) return

    // Asked of the presence controller rather than answered here, so a
    // gateway-backed agent reads the same on its message avatar as it does on
    // the participant strip. Without a presence controller (this menu rendered
    // outside the chat popup) chat presence is all there is.
    const online = this.presenceController
      ? this.presenceController.isUserOnline(this.userIdValue, presentIds)
      : presentIds.some((id) => String(id) === String(this.userIdValue))
    this.statusTarget.classList.toggle('is-online', online)
    this.statusLabelTarget.textContent = online
      ? this.statusTarget.dataset.onlineText
      : this.statusTarget.dataset.offlineText
  }
}
