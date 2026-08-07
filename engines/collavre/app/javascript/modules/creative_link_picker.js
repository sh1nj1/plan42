import { getCaretClientRect } from '../utils/caret_position'

const MARKDOWN_SPECIAL = /[\\`*_\[\]()<>~]/g

export function escapeMarkdownLabel(label) {
  return String(label || '').replace(MARKDOWN_SPECIAL, (character) => `\\${character}`)
}

export function markdownCreativeCommandRange(value, caretPosition) {
  const beforeCaret = String(value || '').slice(0, caretPosition)
  const match = beforeCaret.match(/(?:^|\n)(\/creative)$/)
  if (!match) return null

  return {
    start: caretPosition - match[1].length,
    end: caretPosition,
  }
}

export function insertMarkdownCreativeLink(textarea, item) {
  if (!textarea || !item?.id) return false

  const position = textarea.selectionStart
  const link = `[${escapeMarkdownLabel(item.label)}](/creatives/${item.id})`
  textarea.setRangeText(`${link} `, position, textarea.selectionEnd, 'end')
  textarea.dispatchEvent(new Event('input', { bubbles: true }))
  textarea.focus()
  return true
}

export function openCreativeLinkPicker(textarea, {
  triggerRange = null,
  allowCreate = true,
} = {}) {
  if (!textarea) return false

  const modal = document.getElementById('link-creative-modal')
  const controller = modal && window.Stimulus?.getControllerForElementAndIdentifier(
    modal,
    'link-creative'
  )
  if (!controller) return false

  if (triggerRange) {
    textarea.setRangeText('', triggerRange.start, triggerRange.end, 'end')
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
  }

  const caretRect = getCaretClientRect(textarea) || textarea.getBoundingClientRect()
  controller.open(
    caretRect,
    (item) => insertMarkdownCreativeLink(textarea, item),
    () => textarea.focus(),
    { allowCreate }
  )
  return true
}
