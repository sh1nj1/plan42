/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import FormController from '../form_controller'
import CommentController from '../../comment_controller'

// jsdom has no CSS.escape; creative_quote uses it to build row selectors.
if (!globalThis.CSS?.escape) {
  globalThis.CSS = { ...(globalThis.CSS || {}), escape: (value) => String(value).replace(/["\\]/g, '\\$&') }
}

describe('FormController - Review Quote Chips', () => {
  let application
  let container
  let controller

  beforeEach(async () => {
    if (!global.DataTransfer) {
      global.DataTransfer = class {
        constructor() {
          this.files = []
          this.items = {
            add: (file) => this.files.push(file),
          }
        }
      }
    }

    container = document.createElement('div')
    container.innerHTML = `
      <div id="comments-popup"
           data-controller="comments--form"
           data-review-feedback-placeholder="Write feedback for this quote..."
           data-review-summary-placeholder="Overall comment (optional)..."
           data-review-add-quote="+ Add"
           data-review-send="Send review"
           data-review-send-question="Send question"
           data-review-type-review="💬"
           data-review-type-question="❓"
           data-review-type-review-label="Review"
           data-review-type-question-label="Question">
        <form data-comments--form-target="form">
          <input type="hidden" name="comment[quoted_comment_id]" data-comments--form-target="quotedCommentId" value="" />
          <input type="hidden" name="comment[quoted_text]" data-comments--form-target="quotedText" value="" />
          <div data-comments--form-target="quoteIndicator" style="display:none;">
            <span data-comments--form-target="quoteIndicatorText"></span>
          </div>
          <div class="review-quotes-container" data-comments--form-target="reviewQuotesContainer" style="display:none;"></div>
          <textarea data-comments--form-target="textarea" rows="2"></textarea>
          <input type="checkbox" data-comments--form-target="privateCheckbox" />
          <button type="submit" data-comments--form-target="submit">Send</button>
          <button data-comments--form-target="cancel" style="display:none;">Cancel</button>
          <button data-comments--form-target="moveButton" style="display:none;">Move</button>
          <button data-comments--form-target="searchButton" style="display:none;">Search</button>
          <button data-comments--form-target="voiceButton" style="display:none;">Voice</button>
          <input type="file" data-comments--form-target="imageInput" style="display:none;" />
          <button data-comments--form-target="imageButton" style="display:none;">Image</button>
          <div data-comments--form-target="attachmentList"></div>
          <select name="comment[agent_run_options][reasoning_effort]">
            <option value="">Agent default</option>
            <option value="max">max</option>
          </select>
        </form>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--form', FormController)

    await new Promise((resolve) => setTimeout(resolve, 50))
    const el = container.querySelector('#comments-popup')
    controller = application.getControllerForElementAndIdentifier(el, 'comments--form')
  })

  afterEach(() => {
    application.stop()
    document.body.removeChild(container)
  })

  // Helper accessors for the refactored store-based API
  const getQuotes = (ctrl) => ctrl._reviewStore.quotes
  const getActiveId = (ctrl) => ctrl._reviewStore.activeId

  describe('auto focus on open', () => {
    test('passes the original opening control to deferred autofocus', async () => {
      const reset = jest.spyOn(controller, 'resetForm').mockImplementation(() => {})
      const openingControl = document.createElement('button')
      container.append(openingControl)
      openingControl.focus()
      controller.onPopupOpened({ creativeId: '123', canComment: true, openingControl })
      await new Promise(resolve => requestAnimationFrame(resolve))
      expect(document.activeElement).toBe(controller.textareaTarget)
      reset.mockRestore()
    })

    test('skips initial focus when popup opts out', () => {
      container.querySelector('#comments-popup').dataset.autoFocusOnOpen = 'false'
      const resetFormSpy = jest.spyOn(controller, 'resetForm').mockImplementation(() => {})
      const focusSpy = jest.spyOn(controller.textareaTarget, 'focus').mockImplementation(() => {})

      controller.onPopupOpened({ creativeId: '123', canComment: true })

      expect(focusSpy).not.toHaveBeenCalled()
      focusSpy.mockRestore()
      resetFormSpy.mockRestore()
    })

    test('skips initial focus on mobile even when autoFocusOnOpen is true', () => {
      container.querySelector('#comments-popup').dataset.autoFocusOnOpen = 'true'
      const resetFormSpy = jest.spyOn(controller, 'resetForm').mockImplementation(() => {})
      const focusSpy = jest.spyOn(controller.textareaTarget, 'focus').mockImplementation(() => {})
      const originalInnerWidth = window.innerWidth
      Object.defineProperty(window, 'innerWidth', { value: 760, configurable: true })

      controller.onPopupOpened({ creativeId: '123', canComment: true })

      expect(focusSpy).not.toHaveBeenCalled()
      Object.defineProperty(window, 'innerWidth', { value: originalInnerWidth, configurable: true })
      focusSpy.mockRestore()
      resetFormSpy.mockRestore()
    })
  })

  describe('quoteComment', () => {
    test.each(['Quoted text', 'A'.repeat(81)])('quotes selected text and explicitly focuses the composer: %s', (text) => {
      const otherInput = document.createElement('input')
      container.appendChild(otherInput)
      otherInput.focus()
      expect(document.activeElement).toBe(otherInput)

      controller.quoteComment(42, text)

      expect(controller.quotedCommentIdTarget.value).toBe('42')
      expect(controller.quotedTextTarget.value).toBe(text)
      expect(controller.quoteIndicatorTarget.style.display).toBe('')
      expect(controller.quoteIndicatorTextTarget.textContent).toBe(
        text.length > 80 ? text.substring(0, 80) + '…' : text,
      )
      expect(document.activeElement).toBe(controller.textareaTarget)
    })

    test.each([[null, 'text'], [42, '']])('ignores an incomplete quote (%s, %s)', (id, text) => {
      const focus = jest.spyOn(controller.textareaTarget, 'focus')
      try {
        controller.quoteComment(id, text)

        expect(controller.quotedCommentIdTarget.value).toBe('')
        expect(controller.quotedTextTarget.value).toBe('')
        expect(controller.quoteIndicatorTarget.style.display).toBe('none')
        expect(focus).not.toHaveBeenCalled()
      } finally {
        focus.mockRestore()
      }
    })
  })

  test.each(['popup', 'button'])('review %s clears the message selection before focusing the composer', (entry) => {
    const comment = document.createElement('div')
    comment.dataset.commentId = '42'
    comment.innerHTML = '<div class="comment-content">Selected message</div>'
    container.querySelector('#comments-popup').appendChild(comment)
    const commentController = Object.create(CommentController.prototype)
    Object.defineProperty(commentController, 'element', { value: comment })
    commentController.findFormController = () => controller
    const selection = window.getSelection()
    const range = document.createRange()
    range.selectNodeContents(comment.firstElementChild)
    selection.removeAllRanges()
    selection.addRange(range)
    const clearSelection = jest.spyOn(selection, 'removeAllRanges')
    const focus = jest.spyOn(controller.textareaTarget, 'focus')
    controller.textareaTarget.scrollIntoView = jest.fn()

    try {
      if (entry === 'popup') {
        commentController.showReviewPopup(comment.getBoundingClientRect(), selection.toString())
        commentController._quotePopup.popup.handleItemSelect(0)
      } else {
        commentController.reviewClick({ preventDefault: jest.fn() })
      }

      expect(getQuotes(controller)[0]).toMatchObject({ commentId: '42', text: 'Selected message', type: 'review' })
      expect(selection.toString()).toBe('')
      expect(clearSelection).toHaveBeenCalledTimes(1)
      expect(focus).toHaveBeenCalled()
      // In WebKit, clearing ranges after focus removes the textarea's typing caret.
      expect(clearSelection.mock.invocationCallOrder[0]).toBeLessThan(focus.mock.invocationCallOrder[0])
      expect(document.activeElement).toBe(controller.textareaTarget)
    } finally {
      commentController.hideReviewPopup()
      commentController._quotePopup?.destroy()
      clearSelection.mockRestore()
      focus.mockRestore()
    }
  })

  describe('review / ask popup on a chat message', () => {
    let comment
    let commentController

    beforeEach(() => {
      const popupEl = container.querySelector('#comments-popup')
      popupEl.dataset.reviewButtonText = 'Revise'
      popupEl.dataset.askButtonText = 'Ask it'
      comment = document.createElement('div')
      comment.dataset.commentId = '42'
      comment.innerHTML = '<div class="comment-content">Selected message</div>'
      popupEl.appendChild(comment)
      commentController = Object.create(CommentController.prototype)
      Object.defineProperty(commentController, 'element', { value: comment })
      commentController.findFormController = () => controller
      controller.textareaTarget.scrollIntoView = jest.fn()
    })

    afterEach(() => {
      commentController._quotePopup?.destroy()
    })

    test('renders Review and Ask items inside the comments popup', () => {
      commentController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'Selected message')

      const popupEl = container.querySelector('#comments-popup .quote-selection-popup')
      expect(popupEl).not.toBeNull()
      expect(popupEl.style.display).toBe('block')
      const items = [...popupEl.querySelectorAll('li')].map(li => li.textContent)
      expect(items).toEqual(['Revise', 'Ask it'])
    })

    test('reuses one popup across selections', () => {
      commentController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'one')
      const first = commentController._quotePopup
      commentController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'two')
      expect(commentController._quotePopup).toBe(first)
      expect(container.querySelectorAll('.quote-selection-popup')).toHaveLength(1)
    })

    test('picking Ask adds a question quote for the message', () => {
      commentController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'Selected message')
      container.querySelectorAll('.quote-selection-popup li')[1].click()

      expect(getQuotes(controller)).toHaveLength(1)
      expect(getQuotes(controller)[0]).toMatchObject({ commentId: '42', text: 'Selected message', type: 'question', creativeId: null })
      expect(controller.quotedCommentIdTarget.value).toBe('42')
      expect(commentController._quotePopup.element.style.display).toBe('none')
      expect(controller.submitTarget.textContent).toBe('Send question')
    })

    test('pickQuoteAction without a form controller only clears the selection and hides', () => {
      commentController.findFormController = () => null
      commentController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'Selected message')
      commentController.pickQuoteAction('review')

      expect(getQuotes(controller)).toHaveLength(0)
      expect(commentController._quotePopup.element.style.display).toBe('none')
    })

    test('falls back to document.body when not inside the comments popup', () => {
      const loose = document.createElement('div')
      loose.dataset.commentId = '7'
      document.body.appendChild(loose)
      const looseController = Object.create(CommentController.prototype)
      Object.defineProperty(looseController, 'element', { value: loose })
      looseController.findFormController = () => controller
      try {
        looseController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'loose')
        const el = looseController._quotePopup.element
        expect(el.parentElement).toBe(document.body)
        expect([...el.querySelectorAll('li')].map(li => li.textContent)).toEqual(['Review', 'Ask'])
      } finally {
        looseController._quotePopup.destroy()
        loose.remove()
      }
    })

    test('disconnect removes the popup element', () => {
      commentController.showReviewPopup({ left: 0, right: 10, top: 0, bottom: 10, width: 10 }, 'Selected message')
      const el = commentController._quotePopup.element
      commentController.disconnect()
      expect(el.isConnected).toBe(false)
      expect(commentController._quotePopup).toBeNull()
      expect(() => commentController.disconnect()).not.toThrow()
    })

    test('mouseup on a message selection shows the popup', () => {
      const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation((cb) => { cb(0); return 1 })
      const hadRect = 'getBoundingClientRect' in Range.prototype
      if (!hadRect) Range.prototype.getBoundingClientRect = () => ({ left: 0, right: 0, top: 0, bottom: 0, width: 0 })
      try {
        const range = document.createRange()
        range.selectNodeContents(comment.querySelector('.comment-content'))
        window.getSelection().removeAllRanges()
        window.getSelection().addRange(range)

        commentController.handleMouseUp()

        expect(commentController._pendingQuoteText).toBe('Selected message')
        expect(commentController._quotePopup.element.style.display).toBe('block')
      } finally {
        window.getSelection().removeAllRanges()
        if (!hadRect) delete Range.prototype.getBoundingClientRect
        raf.mockRestore()
      }
    })

    test('hideReviewPopup is safe before any popup exists', () => {
      expect(() => commentController.hideReviewPopup()).not.toThrow()
    })
  })

  describe('appendReviewQuote', () => {
    test('adds a review quote chip', () => {
      controller.appendReviewQuote(42, 'Hello world')

      expect(getQuotes(controller)).toHaveLength(1)
      expect(getQuotes(controller)[0]).toMatchObject({
        commentId: 42,
        text: 'Hello world',
        type: 'review',
        feedback: '',
      })
      expect(container.querySelectorAll('.review-quote-chip')).toHaveLength(1)
    })

    test('sets active quote id', () => {
      controller.appendReviewQuote(1, 'text')
      expect(getActiveId(controller)).toBe(getQuotes(controller)[0].id)
    })

    test('saves previous active quote feedback', () => {
      controller.appendReviewQuote(1, 'first')
      controller.textareaTarget.value = 'feedback for first'
      controller.appendReviewQuote(2, 'second')

      expect(getQuotes(controller)[0].feedback).toBe('feedback for first')
      expect(getQuotes(controller)[1].feedback).toBe('')
      expect(controller.textareaTarget.value).toBe('')
    })

    test('sets placeholder to feedback prompt', () => {
      controller.appendReviewQuote(1, 'text')
      expect(controller.textareaTarget.placeholder).toBe('Write feedback for this quote...')
    })

    test('ignores empty text', () => {
      controller.appendReviewQuote(1, '')
      expect(getQuotes(controller)).toHaveLength(0)
    })

    test('ignores null text', () => {
      controller.appendReviewQuote(1, null)
      expect(getQuotes(controller)).toHaveLength(0)
    })

    test('accumulates multiple quotes', () => {
      controller.appendReviewQuote(1, 'first')
      controller.appendReviewQuote(2, 'second')
      controller.appendReviewQuote(3, 'third')

      expect(getQuotes(controller)).toHaveLength(3)
      expect(container.querySelectorAll('.review-quote-chip')).toHaveLength(3)
    })
  })

  describe('_commitActiveQuote', () => {
    test('saves feedback and deactivates', () => {
      controller.appendReviewQuote(1, 'text')
      controller.textareaTarget.value = 'my feedback'
      controller._commitActiveQuote()

      expect(getQuotes(controller)[0].feedback).toBe('my feedback')
      expect(getActiveId(controller)).toBeNull()
      expect(controller.textareaTarget.value).toBe('')
      expect(controller.textareaTarget.placeholder).toBe('Overall comment (optional)...')
    })
  })

  describe('_updateSubmitButton', () => {
    test('default state when no quotes', () => {
      controller._updateSubmitButton()
      expect(controller.submitTarget.classList.contains('review-submit-btn')).toBe(false)
    })

    test('"+ Add" when active review quote', () => {
      controller.appendReviewQuote(1, 'text')
      expect(controller.submitTarget.textContent).toBe('+ Add')
      expect(controller.submitTarget.classList.contains('review-submit-btn')).toBe(true)
    })

    test('"Send question" when active question quote', () => {
      controller.appendReviewQuote(1, 'text')
      controller._reviewStore.toggleType(getQuotes(controller)[0].id)
      controller._updateSubmitButton()
      expect(controller.submitTarget.textContent).toBe('Send question')
    })

    test('"Send review" when all quotes committed', () => {
      controller.appendReviewQuote(1, 'text')
      controller._commitActiveQuote()
      expect(controller.submitTarget.textContent).toBe('Send review')
    })
  })

  describe('_buildReviewContent (via store.buildContent)', () => {
    test('builds markdown from review quotes with feedback', () => {
      controller.appendReviewQuote(1, 'line one')
      controller.textareaTarget.value = 'good'
      controller._commitActiveQuote()
      controller.textareaTarget.value = ''

      const content = controller._reviewStore.buildContent(controller.textareaTarget.value)
      expect(content).toContain('> line one')
      expect(content).toContain('good')
    })

    test('blank line between quotes prevents blockquote merging', () => {
      controller.appendReviewQuote(1, 'first')
      controller._commitActiveQuote()
      controller.appendReviewQuote(2, 'second')
      controller._commitActiveQuote()
      controller.textareaTarget.value = ''

      const content = controller._reviewStore.buildContent(controller.textareaTarget.value)
      const lines = content.split('\n')
      const firstIdx = lines.indexOf('> first')
      const secondIdx = lines.indexOf('> second')
      expect(secondIdx).toBeGreaterThan(firstIdx + 1)
      expect(lines[firstIdx + 1]).toBe('')
    })

    test('summary after --- separator', () => {
      controller.appendReviewQuote(1, 'quoted')
      controller.textareaTarget.value = 'fix'
      controller._commitActiveQuote()

      const content = controller._reviewStore.buildContent('overall good')
      expect(content).toContain('---')
      expect(content).toContain('overall good')
    })

    test('no summary: no --- separator', () => {
      controller.appendReviewQuote(1, 'quoted')
      controller.textareaTarget.value = 'fix'
      controller._commitActiveQuote()

      const content = controller._reviewStore.buildContent('')
      expect(content).not.toContain('---')
    })

    test('question type uses ❓ prefix', () => {
      controller.appendReviewQuote(1, 'why?')
      controller._reviewStore.toggleType(getQuotes(controller)[0].id)
      controller._commitActiveQuote()
      controller.textareaTarget.value = ''

      const content = controller._reviewStore.buildContent(controller.textareaTarget.value)
      expect(content).toContain('> ❓ why?')
    })
  })

  describe('type toggle', () => {
    test('toggles between review and question', () => {
      controller.appendReviewQuote(1, 'text')
      expect(getQuotes(controller)[0].type).toBe('review')

      container.querySelector('.review-quote-type-toggle').click()
      expect(getQuotes(controller)[0].type).toBe('question')

      container.querySelector('.review-quote-type-toggle').click()
      expect(getQuotes(controller)[0].type).toBe('review')
    })

    test('updates button text on toggle', () => {
      controller.appendReviewQuote(1, 'text')
      expect(controller.submitTarget.textContent).toBe('+ Add')

      container.querySelector('.review-quote-type-toggle').click()
      expect(controller.submitTarget.textContent).toBe('Send question')
    })
  })

  describe('chip removal', () => {
    test('resets UI when last chip removed', () => {
      controller.appendReviewQuote(1, 'text')
      container.querySelector('.review-quote-chip-remove').click()

      expect(getQuotes(controller)).toHaveLength(0)
      expect(getActiveId(controller)).toBeNull()
      expect(controller.textareaTarget.placeholder).toBe('Type a message, or use / for commands')
      expect(container.querySelector('.review-quotes-container').style.display).toBe('none')
    })

    test('preserves other quotes', () => {
      controller.appendReviewQuote(1, 'first')
      controller._commitActiveQuote()
      controller.appendReviewQuote(2, 'second')
      controller._commitActiveQuote()

      container.querySelectorAll('.review-quote-chip-remove')[0].click()

      expect(getQuotes(controller)).toHaveLength(1)
      expect(getQuotes(controller)[0].text).toBe('second')
    })
  })

  describe('cancelQuote', () => {
    test('clears all review state', () => {
      controller.appendReviewQuote(1, 'text')
      controller.cancelQuote()

      expect(getQuotes(controller)).toHaveLength(0)
      expect(getActiveId(controller)).toBeNull()
      expect(controller.textareaTarget.placeholder).toBe('Type a message, or use / for commands')
    })
  })

  describe('chip click - feedback editing', () => {
    test('clicking committed chip loads its feedback', () => {
      controller.appendReviewQuote(1, 'first')
      controller.textareaTarget.value = 'feedback1'
      controller._commitActiveQuote()
      controller.appendReviewQuote(2, 'second')
      controller._commitActiveQuote()

      container.querySelectorAll('.review-quote-chip-text')[0].click()

      expect(getActiveId(controller)).toBe(getQuotes(controller)[0].id)
      expect(controller.textareaTarget.value).toBe('feedback1')
    })

    test('switching chips saves current feedback', () => {
      controller.appendReviewQuote(1, 'first')
      controller.textareaTarget.value = 'fb1'
      controller._commitActiveQuote()
      controller.appendReviewQuote(2, 'second')
      controller.textareaTarget.value = 'fb2'
      controller._commitActiveQuote()

      // Click first chip
      container.querySelectorAll('.review-quote-chip-text')[0].click()
      // Type new feedback
      controller.textareaTarget.value = 'fb1-updated'
      // Click second chip
      container.querySelectorAll('.review-quote-chip-text')[1].click()

      expect(getQuotes(controller)[0].feedback).toBe('fb1-updated')
      expect(controller.textareaTarget.value).toBe('fb2')
    })
  })

  describe('active chip re-click - programmatic scroll', () => {
    // Re-clicking the active chip scrolls its quoted comment into view. That is a
    // programmatic list scroll, so it must drop the prev-message anchor the same way
    // scrollToBottom/highlightComment do — otherwise a stale anchor inside the corridor
    // survives and the next previous-message click skips the comment now in view.
    test('re-clicking the active chip notifies the list of a programmatic scroll', () => {
      const commentEl = document.createElement('div')
      commentEl.setAttribute('data-comment-id', '1')
      commentEl.scrollIntoView = jest.fn() // jsdom has no scrollIntoView
      document.body.appendChild(commentEl)

      const notifyProgrammaticScroll = jest.fn()
      jest
        .spyOn(controller, 'listController', 'get')
        .mockReturnValue({ notifyProgrammaticScroll })

      controller.appendReviewQuote(1, 'first') // freshly appended quote is active
      container.querySelector('.review-quote-chip-text').click()

      expect(commentEl.scrollIntoView).toHaveBeenCalled()
      expect(notifyProgrammaticScroll).toHaveBeenCalled()

      commentEl.remove()
    })
  })

  describe('document-mode (creative) quotes', () => {
    let creativeSeq = 0
    let fetchMock
    let originalFetch
    let meta
    let tree

    beforeEach(() => {
      fetchMock = jest.fn(() => new Promise(() => {}))
      originalFetch = global.fetch
      global.fetch = fetchMock
      meta = document.createElement('meta')
      meta.name = 'csrf-token'
      meta.content = 'token'
      document.head.appendChild(meta)
      tree = document.createElement('div')
      tree.innerHTML = `
        <creative-tree-row creative-id="10"><div class="creative-content">Root</div></creative-tree-row>
        <creative-tree-row creative-id="11" parent-id="10"><div class="creative-content">Child A</div></creative-tree-row>
        <creative-tree-row creative-id="12" parent-id="10"><div class="creative-content">Child B</div></creative-tree-row>
      `
      document.body.appendChild(tree)
      // Sends never settle here, so each test uses its own creative to stay
      // clear of the module-level in-flight guard.
      controller.creativeId = `doc-${++creativeSeq}`
    })

    afterEach(() => {
      global.fetch = originalFetch
      meta.remove()
      tree.remove()
    })

    test('appendReviewQuote keeps creative quotes apart from the quoted message id', () => {
      controller.appendReviewQuote(42, 'Child A', { type: 'question', creativeId: '11', label: 'Child A' })

      expect(getQuotes(controller)[0]).toMatchObject({ commentId: null, creativeId: '11', label: 'Child A', type: 'question' })
      expect(controller.quotedCommentIdTarget.value).toBe('')
    })

    test('review send carries the common ancestor creative and first quote text, not a message id', () => {
      controller.appendReviewQuote(99, 'message text')
      controller._commitActiveQuote()
      controller.appendReviewQuote(null, 'Child A', { creativeId: '11', label: 'Child A' })
      controller.textareaTarget.value = 'shorten'
      controller._commitActiveQuote()
      controller.appendReviewQuote(null, 'Child B', { creativeId: '12', label: 'Child B' })
      controller._commitActiveQuote()
      expect(controller.quotedCommentIdTarget.value).toBe('99')

      controller.handleSend({ preventDefault: jest.fn() })

      expect(fetchMock).toHaveBeenCalledTimes(1)
      const body = fetchMock.mock.calls[0][1].body
      expect(body.get('comment[review_type]')).toBe('review')
      expect(body.get('comment[quoted_creative_id]')).toBe('10')
      expect(body.get('comment[quoted_text]')).toBe('Child A')
      expect(body.has('comment[quoted_comment_id]')).toBe(false)
      expect(controller.textareaTarget.value).toContain('> Child A')
      expect(controller._pendingCreativeQuote).toBeNull()
    })

    test('review send of message quotes only keeps quoted_comment_id', () => {
      controller.appendReviewQuote(99, 'message text')
      controller._commitActiveQuote()

      controller.handleSend({ preventDefault: jest.fn() })

      const body = fetchMock.mock.calls[0][1].body
      expect(body.get('comment[review_type]')).toBe('review')
      expect(body.get('comment[quoted_comment_id]')).toBe('99')
      expect(body.has('comment[quoted_creative_id]')).toBe(false)
    })

    test('question send of a creative quote carries quoted_creative_id and quoted_text', () => {
      controller._sendQuestionQuote({ id: 'q1', commentId: null, creativeId: '11', text: 'Child A', type: 'question', feedback: 'Why?' })

      const body = fetchMock.mock.calls[0][1].body
      expect(body.get('comment[review_type]')).toBe('question')
      expect(body.get('comment[quoted_creative_id]')).toBe('11')
      expect(body.get('comment[quoted_text]')).toBe('Child A')
      expect(body.has('comment[quoted_comment_id]')).toBe(false)
    })

    test('chip shows the document source label using data-creative-quote-prefix', () => {
      container.querySelector('#comments-popup').dataset.creativeQuotePrefix = 'Document'
      controller.appendReviewQuote(null, 'Child A', { creativeId: '11', label: 'Child A' })

      const source = container.querySelector('.review-quote-chip-text .review-quote-chip-source')
      expect(source.textContent).toBe('📄 Document: Child A')
      expect(source.title).toBe('Child A')
    })

    test('chip source label without a label shows only the prefix', () => {
      controller.appendReviewQuote(null, 'Child A', { creativeId: '11' })

      const source = container.querySelector('.review-quote-chip-source')
      expect(source.textContent).toBe('📄 Doc')
      expect(source.title).toBe('')
    })

    test('message chips have no source label', () => {
      controller.appendReviewQuote(1, 'message')
      expect(container.querySelector('.review-quote-chip-source')).toBeNull()
    })

    test('clicking the active creative chip scrolls to its creative row', () => {
      jest.useFakeTimers()
      try {
        const row = tree.querySelector('[creative-id="11"]')
        row.scrollIntoView = jest.fn()
        controller.appendReviewQuote(null, 'Child A', { creativeId: '11', label: 'Child A' })

        container.querySelector('.review-quote-chip-text').click()

        expect(row.scrollIntoView).toHaveBeenCalledWith({ behavior: 'smooth', block: 'center' })
        expect(row.classList.contains('creative-quote-highlight')).toBe(true)
        jest.advanceTimersByTime(2000)
        expect(row.classList.contains('creative-quote-highlight')).toBe(false)
      } finally {
        jest.useRealTimers()
      }
    })
  })

  describe('sending a question quote', () => {
    test('carries the selected agent run options and topic', async () => {
      const fetchMock = jest.fn(() => Promise.resolve({ ok: true, text: () => Promise.resolve('') }))
      const originalFetch = global.fetch
      global.fetch = fetchMock
      const meta = document.createElement('meta')
      meta.name = 'csrf-token'
      meta.content = 'token'
      document.head.appendChild(meta)
      try {
        controller.creativeId = '123'
        controller._mainTopicId = '55'
        container.querySelector('select').value = 'max'

        controller._sendQuestionQuote({ id: 'q1', commentId: 42, text: 'Why?', type: 'question', feedback: 'Explain' })

        expect(fetchMock).toHaveBeenCalledTimes(1)
        const [url, options] = fetchMock.mock.calls[0]
        expect(url).toBe('/creatives/123/comments')
        const body = options.body
        expect(body.get('comment[review_type]')).toBe('question')
        expect(body.get('comment[quoted_comment_id]')).toBe('42')
        expect(body.get('comment[topic_id]')).toBe('55')
        expect(body.get('comment[agent_run_options][reasoning_effort]')).toBe('max')
        expect(body.get('comment[agent_run_options][model]')).toBeNull()
        expect(body.get('comment[quoted_text]')).toBeNull()
        await new Promise((resolve) => setTimeout(resolve, 0))
      } finally {
        global.fetch = originalFetch
        meta.remove()
      }
    })
  })
})
