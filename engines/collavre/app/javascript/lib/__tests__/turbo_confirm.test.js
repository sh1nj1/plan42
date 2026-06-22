/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// Mock the Turbo import so the module installs its confirm method onto a fake
// config we control, instead of pulling in (and starting) the real Turbo.
const fakeTurbo = { config: { forms: {} } }
jest.unstable_mockModule('@hotwired/turbo-rails', () => ({ Turbo: fakeTurbo }))

// Importing the module installs the override (side effect).
await import('../turbo_confirm')

const turboConfirm = fakeTurbo.config.forms.confirm
const modal = () => document.querySelector('.modal-dialog')
const message = () => document.querySelector('.confirm-dialog-message')

afterEach(() => {
  document.body.innerHTML = ''
  document.documentElement.lang = ''
})

test('installs a confirm method on Turbo.config.forms', () => {
  expect(typeof turboConfirm).toBe('function')
})

test('renders the in-app confirm dialog with the Turbo message', () => {
  const form = document.createElement('form')
  turboConfirm('Revoke this token?', form, null)
  expect(modal()).not.toBeNull()
  expect(message().textContent).toBe('Revoke this token?')
  // Cancel button present (it is a confirm, not an alert).
  expect(document.querySelector('.modal-dialog-btn-secondary')).not.toBeNull()
})

test('resolves true when confirmed, false when cancelled', async () => {
  const form = document.createElement('form')

  const okP = turboConfirm('ok?', form, null)
  document.querySelector('.modal-dialog-btn-danger, .modal-dialog-btn-primary').click()
  await expect(okP).resolves.toBe(true)

  const cancelP = turboConfirm('no?', form, null)
  document.querySelector('.modal-dialog-btn-secondary').click()
  await expect(cancelP).resolves.toBe(false)
})

test('styles the confirm button as danger for delete submits', () => {
  const form = document.createElement('form')
  form.setAttribute('data-turbo-method', 'delete')
  turboConfirm('Delete?', form, null)
  expect(document.querySelector('.modal-dialog-btn-danger')).not.toBeNull()
  expect(document.querySelector('.modal-dialog-btn-primary')).toBeNull()
})

test('detects delete via the submitter and the hidden _method input', () => {
  // Submitter carries the method (button_to renders a button submitter).
  const form1 = document.createElement('form')
  const submitter = document.createElement('button')
  submitter.setAttribute('data-turbo-method', 'delete')
  turboConfirm('x', form1, submitter)
  expect(document.querySelector('.modal-dialog-btn-danger')).not.toBeNull()
  document.body.innerHTML = ''

  // Rails non-Turbo fallback: hidden _method=delete input.
  const form2 = document.createElement('form')
  const hidden = document.createElement('input')
  hidden.name = '_method'
  hidden.value = 'delete'
  form2.appendChild(hidden)
  turboConfirm('x', form2, null)
  expect(document.querySelector('.modal-dialog-btn-danger')).not.toBeNull()
})

test('non-destructive submit uses the primary (non-danger) button', () => {
  const form = document.createElement('form')
  form.setAttribute('method', 'post')
  turboConfirm('Proceed?', form, null)
  expect(document.querySelector('.modal-dialog-btn-primary')).not.toBeNull()
  expect(document.querySelector('.modal-dialog-btn-danger')).toBeNull()
})
