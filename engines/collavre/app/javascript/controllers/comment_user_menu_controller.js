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

  visitProfile(event) {
    // Keep the link in the document until its native navigation runs. The
    // parent popup's delegated click handler otherwise hides it during the
    // same event, which can cancel the link activation in some browsers.
    event.stopPropagation()
  }

  mention(event) {
    // This action owns both the command and its close behavior. If the chat
    // composer is unavailable, leave the menu open instead of making a failed
    // mention look successful.
    event?.stopPropagation()
    const mentionMenu = this.application.getControllerForElementAndIdentifier(
      this.popupElement,
      'comments--mention-menu'
    )
    if (!mentionMenu) return

    mentionMenu.insertMention({ id: this.userIdValue, name: this.userNameValue })
    mentionMenu.textareaTarget?.focus()
    this.popupMenuController?.hide()
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

  get popupMenuController() {
    return this.application.getControllerForElementAndIdentifier(this.element, 'popup-menu')
  }

  updatePresence(presentIds) {
    if (!this.hasStatusTarget || !this.hasStatusLabelTarget) return

    // Asked of the presence controller rather than answered here, so a
    // gateway-backed agent reads the same on its message avatar as it does on
    // the participant strip. Without a presence controller (this menu rendered
    // outside the chat popup) chat presence is all there is.
    const state = this.presenceController
      ? this.presenceController.userHealthState(this.userIdValue, presentIds)
      : this.fallbackHealthState(presentIds)
    this.statusTarget.classList.remove('is-online', 'is-offline', 'is-unknown', 'is-check_error')
    this.statusTarget.classList.add(`is-${state.kind}`)
    this.statusLabelTarget.textContent = state.label
  }

  fallbackHealthState(presentIds) {
    const online = presentIds.some((id) => String(id) === String(this.userIdValue))
    return {
      online,
      kind: online ? 'online' : 'offline',
      label: online ? this.statusTarget.dataset.onlineText : this.statusTarget.dataset.offlineText,
    }
  }
}
