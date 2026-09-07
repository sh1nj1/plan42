import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['textarea']

  onPopupOpened() {}

  onPopupClosed() {}

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
