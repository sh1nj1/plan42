/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const createSubscription = jest.fn()

jest.unstable_mockModule('../../services/cable', () => ({
  createSubscription,
}))

const { Application } = await import('@hotwired/stimulus')
const InboxBadgeController = (await import('../inbox_badge_controller')).default

describe('InboxBadgeController', () => {
  let application
  let container
  let subscription

  beforeEach(() => {
    subscription = { unsubscribe: jest.fn() }
    createSubscription.mockReset()
    createSubscription.mockReturnValue(subscription)

    container = document.createElement('div')
    container.setAttribute('data-controller', 'inbox-badge')
    document.body.appendChild(container)

    application = Application.start()
    application.register('inbox-badge', InboxBadgeController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  test('subscribes to the namespaced InboxBadgeChannel on connect', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(createSubscription).toHaveBeenCalledTimes(1)
    expect(createSubscription).toHaveBeenCalledWith({ channel: 'Collavre::InboxBadgeChannel' })
  })

  test('unsubscribes when the controller disconnects', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))

    container.remove()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(subscription.unsubscribe).toHaveBeenCalledTimes(1)
  })
})
