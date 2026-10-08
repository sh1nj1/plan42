/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  confirmDialog: jest.fn(),
  alertDialog: jest.fn()
}))

const { default: ShareModalController } = await import('../share_modal_controller')

const MODAL_HTML = `
  <div id="share-creative-modal" style="display:none">
    <div class="popup-box">
      <h2>Share</h2>
      <div class="share-public-link">
        <input type="text" id="share-public-url" value="https://example.test/p/AbCdEf1234/plan" readonly />
        <button type="button" id="share-public-link-copy" data-copied-message="Copied!">Copy</button>
      </div>
    </div>
  </div>
`

describe('share modal public link', () => {
  let application

  beforeEach(async () => {
    document.body.innerHTML = `
      <div data-controller="share-modal">
        <button id="open" data-action="click->share-modal#open" data-shares-url="/creatives/1/creative_shares"></button>
        <div data-share-modal-target="container"></div>
      </div>
    `
    global.fetch = jest.fn(() => Promise.resolve({ text: () => Promise.resolve(MODAL_HTML) }))
    application = Application.start()
    application.register('share-modal', ShareModalController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application.stop()
    delete window.Plan42
    jest.restoreAllMocks()
  })

  async function openModal() {
    document.getElementById('open').click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  test('copies the public URL with the app clipboard helper and confirms', async () => {
    const copy = jest.fn(() => Promise.resolve())
    window.Plan42 = { copyTextToClipboard: copy }
    await openModal()

    document.getElementById('share-public-link-copy').click()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(copy).toHaveBeenCalledWith('https://example.test/p/AbCdEf1234/plan')
    expect(document.querySelector('.share-modal-message').textContent).toBe('Copied!')
  })

  test('falls back to the browser clipboard', async () => {
    const writeText = jest.fn(() => Promise.resolve())
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    await openModal()

    document.getElementById('share-public-link-copy').click()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(writeText).toHaveBeenCalledWith('https://example.test/p/AbCdEf1234/plan')
  })
})
