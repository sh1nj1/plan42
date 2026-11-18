import CommonPopup from './common_popup'

// The "Review / Ask" popup shown under a text selection, shared by chat
// messages and document mode so both offer the same two actions.
//   review   — revise the selected part (message version-up / creative draft)
//   question — ask about it without changing anything

function escapeHtml(text) {
  const div = document.createElement('div')
  div.textContent = text ?? ''
  // innerHTML leaves quotes alone; they must not end the title attribute.
  return div.innerHTML.replace(/"/g, '&quot;')
}

// Labels come from data attributes on the comments popup (i18n), with English
// fallbacks for pages that render without it.
export function quoteActionItems(dataset = {}) {
  return [
    { type: 'review', label: dataset.reviewButtonText || 'Review', hint: dataset.reviewButtonHint || '' },
    { type: 'question', label: dataset.askButtonText || 'Ask', hint: dataset.askButtonHint || '' },
  ]
}

export default class QuoteSelectionPopup {
  constructor({ container = document.body, onPick }) {
    const el = document.createElement('div')
    el.className = 'common-popup comment-review-popup quote-selection-popup'
    el.style.display = 'none'
    el.style.padding = '0.3em'
    const list = document.createElement('ul')
    list.style.listStyle = 'none'
    list.style.margin = '0'
    list.style.padding = '0'
    el.appendChild(list)
    container.appendChild(el)

    this.element = el
    this.popup = new CommonPopup(el, {
      onSelect: (item) => onPick(item.type),
      renderItem: (item) => `<span title="${escapeHtml(item.hint)}">${escapeHtml(item.label)}</span>`,
    })
  }

  // Positioned below the selection end from a derived rect rather than a live
  // anchor provider: picking an action clears the selection, so there would be
  // nothing left to re-measure.
  show(anchorRect, items) {
    const belowRect = {
      left: anchorRect.left,
      right: anchorRect.right,
      top: anchorRect.bottom,
      bottom: anchorRect.bottom + 4,
      width: anchorRect.width,
    }
    this.popup.setItems(items)
    this.popup.showAt(belowRect)
  }

  hide() {
    this.popup.hide()
  }

  destroy() {
    this.hide()
    this.element.remove()
  }
}
