/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import TranslationPreferenceController from '../translation_preference_controller'

test('profile submission discards snapshots with stale reader preferences', async () => {
  const snapshots = new Map([
    ['/on-reader', '<span data-controller="comment-translation"></span>'],
    ['/off-reader', '<template></template>'],
  ])
  window.Turbo = { cache: { clear: jest.fn(() => snapshots.clear()) } }
  document.body.innerHTML = '<form><div data-controller="translation-preference"></div></form>'
  const application = Application.start()
  application.register('translation-preference', TranslationPreferenceController)
  await new Promise(resolve => setTimeout(resolve, 0))

  expect(snapshots.size).toBe(2)
  document.querySelector('form').dispatchEvent(new CustomEvent('turbo:submit-start', { bubbles: true }))
  expect(window.Turbo.cache.clear).toHaveBeenCalledTimes(1)
  expect(snapshots.size).toBe(0)

  const form = document.querySelector('form')
  document.body.innerHTML = ''
  await new Promise(resolve => setTimeout(resolve, 0))
  form.dispatchEvent(new CustomEvent('turbo:submit-start', { bubbles: true }))
  expect(window.Turbo.cache.clear).toHaveBeenCalledTimes(1)
  application.stop()
  delete window.Turbo
})
