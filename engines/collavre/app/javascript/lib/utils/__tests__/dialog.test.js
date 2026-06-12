/**
 * @jest-environment jsdom
 */
import { alertDialog, confirmDialog, promptDialog } from '../dialog'

const modal = () => document.querySelector('.modal-dialog')
const overlay = () => document.querySelector('.modal-dialog-overlay')
const message = () => document.querySelector('.confirm-dialog-message')
const input = () => document.querySelector('.modal-dialog-input')

afterEach(() => {
  document.body.innerHTML = ''
  document.documentElement.lang = ''
})

describe('alertDialog', () => {
  test('renders a single OK button (no Cancel) with the message', () => {
    alertDialog('Failed to save')
    expect(modal()).not.toBeNull()
    expect(message().textContent).toBe('Failed to save')
    expect(document.querySelector('.modal-dialog-btn-primary')).not.toBeNull()
    expect(document.querySelector('.modal-dialog-btn-secondary')).toBeNull()
  })

  test('resolves (undefined) and removes the modal when OK is clicked', async () => {
    const p = alertDialog('done')
    document.querySelector('.modal-dialog-btn-primary').click()
    await expect(p).resolves.toBeUndefined()
    expect(modal()).toBeNull()
    expect(overlay()).toBeNull()
  })

  test('Enter and Escape both dismiss', async () => {
    const p1 = alertDialog('x')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await expect(p1).resolves.toBeUndefined()

    const p2 = alertDialog('x')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await expect(p2).resolves.toBeUndefined()
  })

  test('renders the message as text, never HTML (no injection)', () => {
    alertDialog('<img src=x onerror=alert(1)>')
    expect(message().textContent).toBe('<img src=x onerror=alert(1)>')
    expect(message().querySelector('img')).toBeNull()
  })
})

describe('promptDialog', () => {
  test('renders a text input seeded with defaultValue plus OK/Cancel', () => {
    promptDialog('New name?', { defaultValue: 'old' })
    expect(message().textContent).toBe('New name?')
    expect(input()).not.toBeNull()
    expect(input().value).toBe('old')
    expect(document.querySelector('.modal-dialog-btn-secondary')).not.toBeNull()
  })

  test('resolves the entered value when confirmed', async () => {
    const p = promptDialog('Name?')
    input().value = 'typed'
    document.querySelector('.modal-dialog-btn-primary').click()
    await expect(p).resolves.toBe('typed')
  })

  test('resolves null when cancelled (parity with native prompt)', async () => {
    const p = promptDialog('Name?', { defaultValue: 'x' })
    document.querySelector('.modal-dialog-btn-secondary').click()
    await expect(p).resolves.toBeNull()
  })

  test('resolves null when dismissed via Escape', async () => {
    const p = promptDialog('Name?', { defaultValue: 'x' })
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await expect(p).resolves.toBeNull()
  })

  test('Enter submits the current input value', async () => {
    const p = promptDialog('Name?')
    input().value = 'viaEnter'
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await expect(p).resolves.toBe('viaEnter')
  })
})

describe('confirmDialog (re-exported from dialog)', () => {
  test('still resolves true/false', async () => {
    const p = confirmDialog('ok?')
    document.querySelector('.modal-dialog-btn-primary').click()
    await expect(p).resolves.toBe(true)
  })
})
