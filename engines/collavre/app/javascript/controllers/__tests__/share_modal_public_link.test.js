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
  test('permission failure restores styling and displays the modal error', async () => {
    fetch.mockResolvedValueOnce({ text: async () => MODAL_HTML.replace('<h2>Share</h2>', '<h2>Share</h2><select class="share-modal-permission-select org-chart-permission-read" data-update-url="/shares/1"><option value="write">Write</option></select>') })
    await openModal()
    const select = document.querySelector('select')
    const original = select.className
    fetch.mockRejectedValueOnce(new Error('offline'))
    select.dispatchEvent(new Event('change'))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(select.className).toBe(original)
    expect(document.querySelector('.share-modal-message').textContent).toBe('An error occurred')
  })

  test('refresh reloads and initializes modal without another opened event', async () => {
    const opened = jest.fn()
    document.addEventListener('share-modal:opened', opened)
    fetch.mockResolvedValueOnce({ text: async () => MODAL_HTML.replace('<h2>Share</h2>', '<h2>Share</h2><form action="/shares/1"><input name="_method" value="delete"><button type="submit">Delete</button></form>') })
    await openModal()
    expect(opened).toHaveBeenCalledTimes(1)
    fetch.mockResolvedValueOnce({ ok: true })
    document.querySelector('form').dispatchEvent(new Event('submit', { cancelable: true }))
    await new Promise(resolve => setTimeout(resolve, 350))
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(document.getElementById('share-creative-modal').style.display).toBe('flex')
    expect(opened).toHaveBeenCalledTimes(1)
    document.removeEventListener('share-modal:opened', opened)
  })

  test('load failure preserves error context and emits no opened event', async () => {
    const error = new Error('offline')
    const log = jest.spyOn(console, 'error').mockImplementation(() => {})
    fetch.mockRejectedValueOnce(error)
    await openModal()
    expect(log).toHaveBeenCalledWith('share-modal: Failed to load modal', error)
    expect(document.getElementById('share-creative-modal')).toBeNull()
  })

})
