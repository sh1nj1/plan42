import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['trigger', 'status', 'statusLabel']
  static values = {
    userId: Number,
    userName: String,
    avatarUrl: String,
    aiUser: Boolean,
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

  dragStart(event) {
    if (!this.aiUserValue || !event.dataTransfer) return

    event.dataTransfer.setData('application/x-agent-drop', JSON.stringify(this.agentData))
    event.dataTransfer.effectAllowed = 'copy'
    this.triggerTarget.classList.add('dragging')
  }

  dragEnd() {
    this.triggerTarget.classList.remove('dragging')
  }

  handlePresenceChanged(event) {
    this.updatePresence(event.detail?.presentIds || [])
  }

  syncPresence() {
    const presence = this.application.getControllerForElementAndIdentifier(
      this.popupElement,
      'comments--presence'
    )
    this.updatePresence(presence?.currentPresentIds || [])
  }

  updatePresence(presentIds) {
    if (!this.hasStatusTarget || !this.hasStatusLabelTarget) return

    const online = presentIds.some((id) => String(id) === String(this.userIdValue))
    this.statusTarget.classList.toggle('is-online', online)
    this.statusLabelTarget.textContent = online
      ? this.statusTarget.dataset.onlineText
      : this.statusTarget.dataset.offlineText
  }

  get agentData() {
    return {
      id: this.userIdValue,
      name: this.userNameValue,
      avatar_url: this.avatarUrlValue,
    }
  }
}
