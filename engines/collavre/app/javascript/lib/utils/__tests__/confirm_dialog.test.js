/**
 * @jest-environment jsdom
 */
import { confirmDialog } from '../confirm_dialog'

const modal = () => document.querySelector('.modal-dialog')
const overlay = () => document.querySelector('.modal-dialog-overlay')
const message = () => document.querySelector('.confirm-dialog-message')

describe('confirmDialog', () => {
  afterEach(() => {
    document.body.innerHTML = ''
    document.documentElement.lang = ''
  })

  test('renders a modal with the message and OK/Cancel buttons', () => {
    confirmDialog('Delete this?')
    expect(modal()).not.toBeNull()
    expect(overlay()).not.toBeNull()
    expect(message().textContent).toBe('Delete this?')
    expect(document.querySelector('.modal-dialog-btn-secondary')).not.toBeNull()
    expect(document.querySelector('.modal-dialog-btn-primary')).not.toBeNull()
  })

  test('resolves true when confirm is clicked, then removes the modal', async () => {
    const p = confirmDialog('ok?')
    document.querySelector('.modal-dialog-btn-primary').click()
    await expect(p).resolves.toBe(true)
    expect(modal()).toBeNull()
    expect(overlay()).toBeNull()
  })

  test('resolves false when cancel is clicked', async () => {
    const p = confirmDialog('x')
    document.querySelector('.modal-dialog-btn-secondary').click()
    await expect(p).resolves.toBe(false)
  })

  test('resolves false when the backdrop is clicked', async () => {
    const p = confirmDialog('x')
    overlay().click()
    await expect(p).resolves.toBe(false)
  })

  test('Enter resolves true, Escape resolves false', async () => {
    const p1 = confirmDialog('x')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await expect(p1).resolves.toBe(true)

    const p2 = confirmDialog('x')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await expect(p2).resolves.toBe(false)
  })

  test('danger option styles the confirm button as destructive', () => {
    confirmDialog('Delete?', { danger: true })
    expect(document.querySelector('.modal-dialog-btn-danger')).not.toBeNull()
    expect(document.querySelector('.modal-dialog-btn-primary')).toBeNull()
  })

  test('renders the message as text, never HTML (no injection)', () => {
    confirmDialog('<img src=x onerror=alert(1)>')
    expect(message().textContent).toBe('<img src=x onerror=alert(1)>')
    expect(message().querySelector('img')).toBeNull()
  })

  test('localizes the buttons from <html lang>', () => {
    document.documentElement.lang = 'ko'
    confirmDialog('삭제?')
    expect(document.querySelector('.modal-dialog-btn-primary').textContent).toBe('확인')
    expect(document.querySelector('.modal-dialog-btn-secondary').textContent).toBe('취소')
  })

  test('only the topmost stacked dialog reacts to keys', async () => {
    const p1 = confirmDialog('first')
    const p2 = confirmDialog('second')
    expect(document.querySelectorAll('.modal-dialog').length).toBe(2)

    // Enter resolves only the topmost (second) dialog.
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await expect(p2).resolves.toBe(true)
    expect(document.querySelectorAll('.modal-dialog').length).toBe(1)

    // The first dialog is now topmost and reacts.
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await expect(p1).resolves.toBe(false)
  })
})
