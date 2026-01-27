import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['textarea', 'participants']

  connect() {
    this.handleParticipantsClick = this.handleParticipantsClick.bind(this)
    this.participantsTarget?.addEventListener('click', this.handleParticipantsClick)
  }

  disconnect() {
    this.participantsTarget?.removeEventListener('click', this.handleParticipantsClick)
  }

  onPopupOpened() {}

  onPopupClosed() {}

  handleParticipantsClick(event) {
    const avatar = event.target.closest('.comment-presence-avatar')
    if (!avatar) return
    const userId = avatar.dataset.userId
    const userName = avatar.dataset.userName
    if (!userId || !userName) return
    this.insertMention({ id: userId, name: userName })
    this.textareaTarget.focus()
  }

  insertMention(user) {
    const textarea = this.textareaTarget
    if (!textarea) return
    const start = textarea.selectionStart
    const end = textarea.selectionEnd
    const mentionText = `@${user.name}: `

    const before = textarea.value.slice(0, start)
    const after = textarea.value.slice(end)
    textarea.value = `${before}${mentionText}${after}`
    textarea.setSelectionRange(start + mentionText.length, start + mentionText.length)
  }
}
