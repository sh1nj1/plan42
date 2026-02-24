/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import FormController from '../form_controller'

describe('FormController - Review Quote Chips', () => {
  let application
  let container
  let controller

  beforeEach(async () => {
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
      expect(controller.textareaTarget.placeholder).toBe('')
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
      expect(controller.textareaTarget.placeholder).toBe('')
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
})
