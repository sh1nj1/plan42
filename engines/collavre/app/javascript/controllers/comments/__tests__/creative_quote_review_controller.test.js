/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application, Controller } from '@hotwired/stimulus'
import CreativeQuoteReviewController from '../creative_quote_review_controller'

const flush = () => new Promise(resolve => setTimeout(resolve, 0))
const load = jest.fn()

class FakeHistoryDetailController extends Controller {
  load(event) { load(event) }
}

let application
let rafSpy

async function start({ open = true, withDetails = true, placeholder = 'Tell the agent what to change', inPopup = true } = {}) {
  const review = `
    <div data-controller="comments--creative-quote-review"
         ${placeholder ? `data-comments--creative-quote-review-reject-placeholder-value="${placeholder}"` : ''}>
      ${withDetails ? `<details data-controller="creative-history-detail" ${open ? 'open' : ''}><summary>Diff</summary></details>` : ''}
    </div>`
  document.body.innerHTML = inPopup
    ? `<div id="comments-popup">${review}<textarea data-comments--form-target="textarea" placeholder="Type"></textarea></div>`
    : review
  application = Application.start()
  application.register('creative-history-detail', FakeHistoryDetailController)
  application.register('comments--creative-quote-review', CreativeQuoteReviewController)
  await flush()
  return application.getControllerForElementAndIdentifier(
    document.querySelector('[data-controller="comments--creative-quote-review"]'),
    'comments--creative-quote-review',
  )
}

beforeEach(() => {
  load.mockClear()
  rafSpy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation((cb) => { setTimeout(() => cb(0), 0); return 1 })
})

afterEach(async () => {
  application.stop()
  rafSpy.mockRestore()
  document.body.innerHTML = ''
  await flush()
})

describe('connect', () => {
  test('loads the diff when the details start open', async () => {
    await start()
    await flush()
    const details = document.querySelector('details')
    expect(load).toHaveBeenCalledWith({ type: 'connect', target: details })
  })

  test.each([
    ['closed details', { open: false }],
    ['no details', { withDetails: false }],
  ])('skips loading with %s', async (_name, options) => {
    await start(options)
    await flush()
    expect(load).not.toHaveBeenCalled()
  })

  test('tolerates a missing history detail controller', async () => {
    document.body.innerHTML = `
      <div data-controller="comments--creative-quote-review">
        <details data-controller="creative-history-detail" open></details>
      </div>`
    application = Application.start()
    application.register('comments--creative-quote-review', CreativeQuoteReviewController)
    await flush()
    await flush()
    expect(load).not.toHaveBeenCalled()
  })
})

describe('applied', () => {
  test('a rejection focuses the chat input with the reject placeholder', async () => {
    const controller = await start()
    const textarea = document.querySelector('textarea')
    controller.applied({ detail: { status: 'rejected' } })
    expect(textarea.placeholder).toBe('Tell the agent what to change')
    expect(document.activeElement).toBe(textarea)
  })

  test('a rejection without a placeholder value only focuses', async () => {
    const controller = await start({ placeholder: '' })
    const textarea = document.querySelector('textarea')
    controller.applied({ detail: { status: 'rejected' } })
    expect(textarea.placeholder).toBe('Type')
    expect(document.activeElement).toBe(textarea)
  })

  test.each([
    ['an applied change', { detail: { status: 'applied' } }],
    ['no detail', {}],
  ])('ignores %s', async (_name, event) => {
    const controller = await start()
    const textarea = document.querySelector('textarea')
    controller.applied(event)
    expect(textarea.placeholder).toBe('Type')
    expect(document.activeElement).not.toBe(textarea)
  })

  test('outside the comments popup, a rejection does nothing', async () => {
    const controller = await start({ inPopup: false })
    expect(() => controller.applied({ detail: { status: 'rejected' } })).not.toThrow()
  })
})
