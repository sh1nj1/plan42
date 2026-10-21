/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application, Controller } from '@hotwired/stimulus'
import DocumentSelectionController from '../document_selection_controller'

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

// jsdom lacks these browser APIs.
if (!globalThis.CSS?.escape) {
  globalThis.CSS = { ...(globalThis.CSS || {}), escape: (value) => String(value).replace(/["\\]/g, '\\$&') }
}
if (!Range.prototype.getBoundingClientRect) {
  Range.prototype.getBoundingClientRect = () => ({ left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 })
}

const appendReviewQuote = jest.fn()
const openChat = jest.fn()

class FakeFormController extends Controller {
  appendReviewQuote(...args) { appendReviewQuote(...args) }
}

class FakePopupController extends Controller {
  async open(button) {
    openChat(button)
    this.element.style.display = 'flex'
  }
}

let application
let originalMatchMedia
let rafSpy

function mount({ documentView = true, commentsPopup = true, chatOpen = false, titleButton = true, rowButton = true } = {}) {
  document.body.innerHTML = `
    <div data-controller="creatives--document-selection" class="${documentView ? 'creative-document-view' : ''}">
      <creative-tree-row creative-id="1">
        <div class="creative-tree creative-tree-title"><div class="creative-title-content">Doc title</div></div>
        ${titleButton ? '<button name="show-comments-btn" class="title-btn"></button>' : ''}
      </creative-tree-row>
      <creative-tree-row creative-id="2" parent-id="1">
        <div class="creative-content">Second paragraph</div>
        ${rowButton ? '<button name="show-comments-btn" class="row-btn"></button>' : ''}
      </creative-tree-row>
    </div>
    ${commentsPopup ? `<div id="comments-popup" data-controller="comments--popup comments--form"
         data-review-button-text="Revise" data-ask-button-text="Ask it"
         style="display: ${chatOpen ? 'flex' : 'none'}"></div>` : ''}
  `
  return document.querySelector('[data-controller="creatives--document-selection"]')
}

function selectRowText(root, id = '2') {
  const range = document.createRange()
  range.selectNodeContents(root.querySelector(`[creative-id="${id}"] .creative-content, [creative-id="${id}"] .creative-title-content`))
  const selection = window.getSelection()
  selection.removeAllRanges()
  selection.addRange(range)
  return selection
}

const controllerOf = (root) => application.getControllerForElementAndIdentifier(root, 'creatives--document-selection')
const quotePopup = () => document.querySelector('.quote-selection-popup')

async function start(options) {
  const root = mount(options)
  application = Application.start()
  application.register('creatives--document-selection', DocumentSelectionController)
  application.register('comments--form', FakeFormController)
  if (options?.popupController !== false) application.register('comments--popup', FakePopupController)
  await flush()
  return root
}

beforeEach(() => {
  appendReviewQuote.mockClear()
  openChat.mockClear()
  originalMatchMedia = window.matchMedia
  window.matchMedia = () => ({ matches: true })
  rafSpy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation((cb) => { cb(0); return 1 })
})

afterEach(async () => {
  application.stop()
  window.matchMedia = originalMatchMedia
  rafSpy.mockRestore()
  window.getSelection().removeAllRanges()
  document.body.innerHTML = ''
  await flush()
})

describe('showing the popup', () => {
  test('a document-mode selection shows Review / Ask with the chat labels', async () => {
    const root = await start()
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))

    const popup = quotePopup()
    expect(popup).not.toBeNull()
    expect(popup.style.display).toBe('block')
    expect([...popup.querySelectorAll('li')].map(li => li.textContent)).toEqual(['Revise', 'Ask it'])
    expect(controllerOf(root).pendingQuote).toEqual({ creativeId: '2', text: 'Second paragraph', label: 'Second paragraph' })
  })

  test('reuses one popup and hides it when the next mouseup has no selection', async () => {
    const root = await start()
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))
    const first = controllerOf(root).popup
    root.dispatchEvent(new MouseEvent('mouseup'))
    expect(controllerOf(root).popup).toBe(first)
    expect(document.querySelectorAll('.quote-selection-popup')).toHaveLength(1)

    window.getSelection().removeAllRanges()
    root.dispatchEvent(new MouseEvent('mouseup'))
    expect(quotePopup().style.display).toBe('none')
  })

  test.each([
    ['outside document view', { documentView: false }, true],
    ['without the comments popup', { commentsPopup: false }, true],
    ['on touch devices', {}, false],
  ])('does nothing %s', async (_name, options, fine) => {
    if (!fine) window.matchMedia = () => ({ matches: false })
    const root = await start(options)
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))
    expect(quotePopup()).toBeNull()
  })

  test('disconnect removes the listener and the popup', async () => {
    const root = await start()
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))
    expect(quotePopup()).not.toBeNull()

    root.removeAttribute('data-controller')
    await flush()
    expect(quotePopup()).toBeNull()

    root.dispatchEvent(new MouseEvent('mouseup'))
    expect(quotePopup()).toBeNull()
  })

  test('disconnect without a popup is safe', async () => {
    const root = await start()
    root.removeAttribute('data-controller')
    await flush()
    expect(quotePopup()).toBeNull()
  })
})

describe('picking an action', () => {
  test('with the chat open, adds the quote to the form and clears the selection', async () => {
    const root = await start({ chatOpen: true })
    const selection = selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))

    quotePopup().querySelectorAll('li')[1].click()
    await flush()

    expect(openChat).not.toHaveBeenCalled()
    expect(appendReviewQuote).toHaveBeenCalledWith(null, 'Second paragraph', { type: 'question', creativeId: '2', label: 'Second paragraph' })
    expect(selection.rangeCount).toBe(0)
    expect(quotePopup().style.display).toBe('none')
    expect(controllerOf(root).pendingQuote).toBeNull()
  })

  test('with the chat closed, opens it from the page title row first', async () => {
    const root = await start()
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))

    quotePopup().querySelectorAll('li')[0].click()
    await flush()

    expect(openChat).toHaveBeenCalledWith(root.querySelector('.title-btn'))
    expect(appendReviewQuote).toHaveBeenCalledWith(null, 'Second paragraph', { type: 'review', creativeId: '2', label: 'Second paragraph' })
  })

  test('without a title button, opens the chat from the quoted row', async () => {
    const root = await start({ titleButton: false })
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))

    await controllerOf(root).pick('review')

    expect(openChat).toHaveBeenCalledWith(root.querySelector('.row-btn'))
    expect(appendReviewQuote).toHaveBeenCalled()
  })

  test('without any comments button, the quote is dropped', async () => {
    const root = await start({ titleButton: false, rowButton: false })
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))

    await controllerOf(root).pick('review')

    expect(openChat).not.toHaveBeenCalled()
    expect(appendReviewQuote).not.toHaveBeenCalled()
  })

  test('without a popup controller, goes straight to the form', async () => {
    const root = await start({ popupController: false })
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))

    await controllerOf(root).pick('review')

    expect(openChat).not.toHaveBeenCalled()
    expect(appendReviewQuote).toHaveBeenCalled()
  })

  // Regression: the pick popup lives in <body> and can outlive a page swap that
  // removes #comments-popup; openChat used to throw on the missing element.
  test('a pick after the comments popup is gone does not throw or add a quote', async () => {
    const root = await start()
    selectRowText(root)
    root.dispatchEvent(new MouseEvent('mouseup'))
    document.getElementById('comments-popup').remove()

    await expect(controllerOf(root).pick('review')).resolves.toBeUndefined()

    expect(openChat).not.toHaveBeenCalled()
    expect(appendReviewQuote).not.toHaveBeenCalled()
    expect(quotePopup().style.display).toBe('none')
  })

  test('openChat returns null without the comments popup', async () => {
    const root = await start({ commentsPopup: false })
    await expect(controllerOf(root).openChat('2')).resolves.toBeNull()
  })

  test('a pick with no pending quote does nothing', async () => {
    const root = await start({ chatOpen: true })
    await controllerOf(root).pick('review')
    expect(appendReviewQuote).not.toHaveBeenCalled()
  })
})
