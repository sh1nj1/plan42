/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import CommentsFormController from '../form_controller'

const COMMENT_HTML =
  '<div id="comment_9" class="comment-item" data-comment-id="9">hello team</div>'

// renderCommentHtml reaches for #comments-list in the document and for the
// sibling list controller through the `listController` getter. Stub both.
const buildController = ({ manualSearchQuery = null } = {}) => {
  document.body.innerHTML = `
    <div id="comments-list">
      <div id="no-search-results" class="comments-placeholder">no results</div>
    </div>
  `

  const listCtrl = {
    manualSearchQuery,
    resetToLatest: jest.fn(),
    markCommentsRead: jest.fn(),
    recordRenderedAllTopicWatermarks: jest.fn(),
  }

  const controller = Object.create(CommentsFormController.prototype)
  Object.defineProperty(controller, 'listController', { get: () => listCtrl })

  return { controller, listCtrl }
}

const listItems = () =>
  document.getElementById('comments-list').querySelectorAll('.comment-item')

describe('CommentsFormController local submit during search', () => {
  test('leaves search and reloads rather than appending into the results', () => {
    const { controller, listCtrl } = buildController({ manualSearchQuery: 'invoice' })

    controller.renderCommentHtml(COMMENT_HTML)

    // The posted comment carries no verdict on whether it matches the query,
    // so it must not be spliced into the result set.
    expect(listItems()).toHaveLength(0)
    expect(listCtrl.resetToLatest).toHaveBeenCalledTimes(1)
  })

  test('keeps the no-results notice instead of clearing it on submit', () => {
    const { controller } = buildController({ manualSearchQuery: 'invoice' })

    controller.renderCommentHtml(COMMENT_HTML)

    // removePlaceholder() clears any .comments-placeholder, so reaching it
    // would strip the explanation and leave an unrelated message alone on
    // screen. resetToLatest() re-renders the list from the server instead.
    expect(document.getElementById('no-search-results')).not.toBeNull()
  })

  test('appends normally when no search is active', () => {
    const { controller, listCtrl } = buildController({ manualSearchQuery: null })

    controller.renderCommentHtml(COMMENT_HTML)

    expect(listItems()).toHaveLength(1)
    expect(listCtrl.resetToLatest).not.toHaveBeenCalled()
    expect(listCtrl.recordRenderedAllTopicWatermarks).toHaveBeenCalledWith(
      document.getElementById('comment_9'),
    )
    // The placeholder is stale once a real comment lands.
    expect(document.getElementById('no-search-results')).toBeNull()
  })

  test('still replaces an edited comment in place during a search', () => {
    // Mirrors the stream path, which blocks `append` but never `replace` /
    // `remove`: the edited comment is already part of the result set, so
    // dropping the update would leave stale text on screen.
    const { controller, listCtrl } = buildController({ manualSearchQuery: 'invoice' })
    document.getElementById('comments-list').insertAdjacentHTML(
      'beforeend',
      '<div id="comment_9" class="comment-item" data-comment-id="9">old text</div>',
    )

    controller.renderCommentHtml(COMMENT_HTML, { replaceExisting: true })

    expect(listCtrl.resetToLatest).not.toHaveBeenCalled()
    expect(document.getElementById('comment_9').textContent).toBe('hello team')
    expect(listItems()).toHaveLength(1)
  })
})
