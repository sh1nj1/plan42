/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

const alertDialog = jest.fn()
jest.unstable_mockModule('../../lib/utils/dialog', () => ({ alertDialog }))

const {
  requireCreativeId,
  resetConnectView,
  showSuccessAndClose,
  sendJson,
  appendLabeledInput,
} = await import('../integration_wizard')

afterEach(() => {
  document.head.innerHTML = ''
  document.body.innerHTML = ''
  jest.clearAllMocks()
  jest.useRealTimers()
})

describe('requireCreativeId', () => {
  function elements(creativeId) {
    const openBtn = document.createElement('button')
    if (creativeId) openBtn.dataset.creativeId = creativeId
    const modal = document.createElement('div')
    modal.dataset.noCreative = 'Pick a creative first'
    return { openBtn, modal }
  }

  test('returns the creative id without alerting', () => {
    const { openBtn, modal } = elements('42')

    expect(requireCreativeId(openBtn, modal)).toBe('42')
    expect(alertDialog).not.toHaveBeenCalled()
  })

  test('alerts with the modal message when the id is missing', () => {
    const { openBtn, modal } = elements(null)

    expect(requireCreativeId(openBtn, modal)).toBeUndefined()
    expect(alertDialog).toHaveBeenCalledWith('Pick a creative first')
  })
})

describe('resetConnectView', () => {
  test('restores every connect step element to its initial state', () => {
    const existingContainer = document.createElement('div')
    existingContainer.style.display = 'block'
    const existingList = document.createElement('ul')
    existingList.innerHTML = '<li>linked</li>'
    const connectMessage = document.createElement('p')
    connectMessage.style.display = 'none'
    const deleteBtn = document.createElement('button')
    deleteBtn.style.display = 'inline-block'
    const loginBtn = document.createElement('button')
    loginBtn.style.display = 'none'

    resetConnectView({ existingContainer, existingList, connectMessage, deleteBtn, loginBtn })

    expect(existingContainer.style.display).toBe('none')
    expect(existingList.innerHTML).toBe('')
    expect(connectMessage.style.display).toBe('')
    expect(deleteBtn.style.display).toBe('none')
    expect(loginBtn.style.display).toBe('inline-block')
  })

  test('skips elements that are not on the page', () => {
    expect(() => resetConnectView({ existingContainer: null, loginBtn: undefined })).not.toThrow()
  })
})

describe('showSuccessAndClose', () => {
  test('shows the message in green and closes the modal after two seconds', () => {
    jest.useFakeTimers()
    const modal = document.createElement('div')
    modal.style.display = 'flex'
    const statusEl = document.createElement('p')
    const onClose = jest.fn()

    showSuccessAndClose(modal, statusEl, 'Saved', onClose)

    expect(statusEl.textContent).toBe('Saved')
    expect(statusEl.style.color).toBe('green')

    jest.advanceTimersByTime(1999)
    expect(modal.style.display).toBe('flex')
    expect(onClose).not.toHaveBeenCalled()

    jest.advanceTimersByTime(1)
    expect(modal.style.display).toBe('none')
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

describe('sendJson', () => {
  const originalFetch = global.fetch

  afterEach(() => {
    global.fetch = originalFetch
  })

  test.each([[true], [false]])('sends a CSRF-protected JSON body and reports ok=%s', async (ok) => {
    document.head.innerHTML = '<meta name="csrf-token" content="token-1">'
    global.fetch = jest.fn().mockResolvedValue({ ok, json: () => Promise.resolve({ error: 'nope' }) })

    const result = await sendJson('/github/creatives/1/integration', 'PATCH', { repositories: ['a/b'] })

    expect(global.fetch).toHaveBeenCalledWith('/github/creatives/1/integration', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'token-1' },
      body: '{"repositories":["a/b"]}',
    })
    expect(result).toEqual({ ok, body: { error: 'nope' } })
  })
})

describe('appendLabeledInput', () => {
  test('wraps the input and its caption in a flex label appended to the container', () => {
    const container = document.createElement('div')
    container.appendChild(document.createElement('p'))
    const input = document.createElement('input')
    input.type = 'checkbox'

    appendLabeledInput(container, input, 'acme/repo')

    const label = container.lastElementChild
    expect(label.tagName).toBe('LABEL')
    expect(label.style.display).toBe('flex')
    expect(label.style.alignItems).toBe('center')
    expect(label.style.gap).toBe('0.5em')
    expect(label.style.marginBottom).toBe('0.5em')
    expect(label.style.cursor).toBe('pointer')
    expect(Array.from(label.children)).toEqual([input, label.querySelector('span')])
    expect(label.querySelector('span').textContent).toBe('acme/repo')
  })
})
