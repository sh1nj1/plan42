import { Controller } from '@hotwired/stimulus'
import QuoteSelectionPopup, { quoteActionItems } from '../../lib/quote_selection_popup'
import { quoteFromSelection, selectionPopupSupported } from '../../lib/creative_quote'

const DOCUMENT_VIEW_CLASS = 'creative-document-view'
const TITLE_ROW_SELECTOR = 'creative-tree-row .creative-tree-title'
const COMMENTS_BUTTON_SELECTOR = '[name="show-comments-btn"]'

// Document mode: selecting text in the document offers the same "Review / Ask"
// popup as a chat message. The pick lands as a quote chip in the chat input —
// opening the page's chat first when it is closed — where the user writes
// what to change or ask. Desktop only; touch devices keep native selection.
export default class extends Controller {
  connect() {
    this.handleMouseUp = this.handleMouseUp.bind(this)
    this.element.addEventListener('mouseup', this.handleMouseUp)
  }

  disconnect() {
    this.element.removeEventListener('mouseup', this.handleMouseUp)
    this.popup?.destroy()
    this.popup = null
  }

  handleMouseUp() {
    // Let the selection settle before reading it.
    requestAnimationFrame(() => {
      this.popup?.hide()
      if (!this.element.classList.contains(DOCUMENT_VIEW_CLASS)) return
      if (!selectionPopupSupported() || !this.commentsPopup) return

      const selection = window.getSelection()
      const quote = quoteFromSelection(selection, this.element)
      if (!quote) return

      this.pendingQuote = quote
      this.popup ||= new QuoteSelectionPopup({ onPick: (type) => this.pick(type) })
      this.popup.show(selection.getRangeAt(0).getBoundingClientRect(), quoteActionItems(this.commentsPopup.dataset))
    })
  }

  async pick(type) {
    const quote = this.pendingQuote
    this.pendingQuote = null
    this.popup?.hide()
    window.getSelection()?.removeAllRanges()
    if (!quote) return

    const form = await this.openChat(quote.creativeId)
    form?.appendReviewQuote(null, quote.text, { type, creativeId: quote.creativeId, label: quote.label })
  }

  // The quote goes to the chat that is open; a closed chat opens on the page's
  // own creative, the document the selection was made in.
  async openChat(creativeId) {
    const popupElement = this.commentsPopup
    // The pick popup lives in <body>, so it can outlive a page swap.
    if (!popupElement) return null
    const popupController = this.controllerFor(popupElement, 'comments--popup')
    if (popupElement.style.display !== 'flex' && popupController) {
      const button = this.element.querySelector(TITLE_ROW_SELECTOR)?.closest('creative-tree-row')
        ?.querySelector(COMMENTS_BUTTON_SELECTOR) ||
        this.element.querySelector(`creative-tree-row[creative-id="${CSS.escape(String(creativeId))}"] ${COMMENTS_BUTTON_SELECTOR}`)
      if (!button) return null
      await popupController.open(button)
    }
    return this.controllerFor(popupElement, 'comments--form')
  }

  controllerFor(element, identifier) {
    return this.application.getControllerForElementAndIdentifier(element, identifier)
  }

  get commentsPopup() {
    return document.getElementById('comments-popup')
  }
}
