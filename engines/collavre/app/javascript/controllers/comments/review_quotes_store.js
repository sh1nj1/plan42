/**
 * ReviewQuotesStore — Pure state management for review quote chips.
 *
 * Responsible for:
 *   - Adding / removing / updating quotes
 *   - Tracking the active (editing) quote
 *   - Building markdown content for submission
 *   - Backup / restore for send-failure rollback
 *
 * Does NOT touch the DOM — the controller handles all rendering.
 */
export default class ReviewQuotesStore {
  constructor() {
    this._quotes = []
    this._activeId = null
    this._backup = null
  }

  // --- Accessors ---

  get quotes() {
    return this._quotes
  }

  get activeId() {
    return this._activeId
  }

  set activeId(id) {
    this._activeId = id
  }

  get activeQuote() {
    if (!this._activeId) return null
    return this._quotes.find(q => q.id === this._activeId) || null
  }

  get count() {
    return this._quotes.length
  }

  get isEmpty() {
    return this._quotes.length === 0
  }

  get hasActive() {
    return this._activeId !== null
  }

  // --- Mutations ---

  add(commentId, text) {
    const quote = {
      id: Date.now(),
      commentId,
      text,
      type: 'review', // 'review' | 'question'
      feedback: '',
    }
    this._quotes.push(quote)
    this._activeId = quote.id
    return quote
  }

  remove(quoteId) {
    const idx = this._quotes.findIndex(q => q.id === quoteId)
    if (idx === -1) return null
    const [removed] = this._quotes.splice(idx, 1)
    if (this._activeId === quoteId) {
      this._activeId = null
    }
    return removed
  }

  setFeedback(quoteId, feedback) {
    const quote = this._quotes.find(q => q.id === quoteId)
    if (quote) quote.feedback = feedback.trim()
  }

  saveActiveFeedback(textareaValue) {
    if (!this._activeId) return
    const quote = this._quotes.find(q => q.id === this._activeId)
    if (quote) quote.feedback = textareaValue.trim()
  }

  commitActive(textareaValue) {
    this.saveActiveFeedback(textareaValue)
    this._activeId = null
  }

  toggleType(quoteId) {
    const quote = this._quotes.find(q => q.id === quoteId)
    if (!quote) return null
    quote.type = quote.type === 'review' ? 'question' : 'review'
    return quote
  }

  activate(quoteId) {
    const quote = this._quotes.find(q => q.id === quoteId)
    if (!quote) return null
    this._activeId = quoteId
    return quote
  }

  clear() {
    this._quotes = []
    this._activeId = null
    this._backup = null
  }

  // --- Backup / Restore (for send-failure rollback) ---

  backup(textareaValue) {
    this._backup = {
      quotes: JSON.parse(JSON.stringify(this._quotes)),
      textareaValue,
    }
  }

  restore() {
    if (!this._backup) return null
    this._quotes = this._backup.quotes
    const textareaValue = this._backup.textareaValue
    this._backup = null
    return textareaValue
  }

  hasBackup() {
    return this._backup !== null
  }

  // --- Markdown Builder ---

  buildContent(summaryText) {
    if (this._quotes.length === 0) return summaryText

    const parts = []

    this._quotes.forEach((q, i) => {
      if (i > 0) parts.push('') // Blank line between quotes to prevent blockquote merging
      const prefix = q.type === 'question' ? '> ❓ ' : '> '
      const quoted = q.text.split('\n').map((line, j) => {
        return j === 0 ? `${prefix}${line}` : `> ${line}`
      }).join('\n')
      parts.push(quoted)
      if (q.feedback) {
        parts.push('')
        parts.push(q.feedback)
      }
    })

    const summary = summaryText.trim()
    if (summary) {
      parts.push('')
      parts.push('---')
      parts.push(summary)
    }

    return parts.join('\n')
  }

  buildQuestionContent(quote) {
    const prefix = '> ❓ '
    const quoted = quote.text.split('\n').map((line, i) => {
      return i === 0 ? `${prefix}${line}` : `> ${line}`
    }).join('\n')
    const parts = [quoted]
    if (quote.feedback) {
      parts.push('')
      parts.push(quote.feedback)
    }
    return parts.join('\n')
  }

  // --- Query ---

  /** Button state: 'add' | 'send-review' | 'send-question' | 'normal' */
  get buttonState() {
    if (this._quotes.length === 0) return 'normal'
    if (this._activeId) {
      const active = this.activeQuote
      if (active && active.type === 'question') return 'send-question'
      return 'add'
    }
    return 'send-review'
  }
}
