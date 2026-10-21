/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import QuoteSelectionPopup, { quoteActionItems } from '../quote_selection_popup'

describe('quoteActionItems', () => {
  test('falls back to English labels', () => {
    expect(quoteActionItems()).toEqual([
      { type: 'review', label: 'Review', hint: '' },
      { type: 'question', label: 'Ask', hint: '' },
    ])
  })

  test('uses i18n labels and hints from the dataset', () => {
    expect(quoteActionItems({
      reviewButtonText: '검토', reviewButtonHint: 'Revise it', askButtonText: '질문', askButtonHint: 'Ask about it',
    })).toEqual([
      { type: 'review', label: '검토', hint: 'Revise it' },
      { type: 'question', label: '질문', hint: 'Ask about it' },
    ])
  })
})

describe('QuoteSelectionPopup', () => {
  const rect = { left: 10, right: 60, top: 20, bottom: 30, width: 50, height: 10 }
  let popup

  afterEach(() => {
    popup?.destroy()
    popup = null
    document.body.innerHTML = ''
  })

  test('mounts a hidden popup in document.body by default', () => {
    popup = new QuoteSelectionPopup({ onPick: jest.fn() })
    expect(popup.element.parentElement).toBe(document.body)
    expect(popup.element.className).toBe('common-popup comment-review-popup quote-selection-popup')
    expect(popup.element.style.display).toBe('none')
    expect(popup.element.querySelector('ul')).not.toBeNull()
  })

  test('mounts into a given container', () => {
    const container = document.createElement('section')
    document.body.appendChild(container)
    popup = new QuoteSelectionPopup({ container, onPick: jest.fn() })
    expect(popup.element.parentElement).toBe(container)
  })

  test('show renders escaped items below the anchor rect', () => {
    popup = new QuoteSelectionPopup({ onPick: jest.fn() })
    const showAt = jest.spyOn(popup.popup, 'showAt')
    popup.show(rect, [
      { type: 'review', label: '<b>Review</b>', hint: 'a <hint> & more' },
      { type: 'question', label: 'Ask' },
    ])

    expect(popup.element.style.display).toBe('block')
    const items = popup.element.querySelectorAll('li')
    expect(items).toHaveLength(2)
    expect(items[0].textContent).toBe('<b>Review</b>')
    expect(items[0].querySelector('b')).toBeNull()
    expect(items[0].querySelector('span').title).toBe('a <hint> & more')
    expect(items[1].querySelector('span').title).toBe('')
    expect(showAt).toHaveBeenCalledWith({ left: 10, right: 60, top: 30, bottom: 34, width: 50 })
  })

  // Regression: escapeHtml left `"` alone, so a quoted hint ended the title
  // attribute early (and could inject attributes).
  test('a hint with double quotes renders as the full title', () => {
    popup = new QuoteSelectionPopup({ onPick: jest.fn() })
    popup.show(rect, [{ type: 'review', label: 'Say "hi"', hint: 'a "hint" onclick="x()"' }])

    const span = popup.element.querySelector('li span')
    expect(span.title).toBe('a "hint" onclick="x()"')
    expect(span.hasAttribute('onclick')).toBe(false)
    expect(span.textContent).toBe('Say "hi"')
  })

  test('picking an item reports its type', () => {
    const onPick = jest.fn()
    popup = new QuoteSelectionPopup({ onPick })
    popup.show(rect, quoteActionItems())
    popup.element.querySelectorAll('li')[1].click()
    expect(onPick).toHaveBeenCalledWith('question')
    popup.element.querySelectorAll('li')[0].click()
    expect(onPick).toHaveBeenLastCalledWith('review')
  })

  test('hide closes and destroy removes the element', () => {
    popup = new QuoteSelectionPopup({ onPick: jest.fn() })
    popup.show(rect, quoteActionItems())
    popup.hide()
    expect(popup.element.style.display).toBe('none')
    const el = popup.element
    popup.destroy()
    expect(el.isConnected).toBe(false)
    popup = null
  })
})
