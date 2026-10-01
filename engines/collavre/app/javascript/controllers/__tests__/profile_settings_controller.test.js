/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import ProfileSettingsController from '../profile_settings_controller'

test('profile submission discards snapshots with stale reader preferences', async () => {
  const snapshots = new Map([
    ['/on-reader', '<span data-controller="comment-translation"></span>'],
    ['/off-reader', '<template></template>'],
  ])
  window.Turbo = { cache: { clear: jest.fn(() => snapshots.clear()) } }
  document.body.innerHTML = '<form data-controller="profile-settings" data-action="turbo:submit-start->profile-settings#clearCache"></form>'
  const application = Application.start()
  application.register('profile-settings', ProfileSettingsController)
  await new Promise(resolve => setTimeout(resolve, 0))

  expect(snapshots.size).toBe(2)
  document.querySelector('form').dispatchEvent(new CustomEvent('turbo:submit-start', { bubbles: true }))
  expect(window.Turbo.cache.clear).toHaveBeenCalledTimes(1)
  expect(snapshots.size).toBe(0)

  application.stop()
  document.body.innerHTML = ''
  delete window.Turbo
})
