/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const createSubscription = jest.fn()
const renderStreamMessage = jest.fn()

jest.unstable_mockModule('../../services/cable', () => ({
  createSubscription,
}))

jest.unstable_mockModule('@hotwired/turbo-rails', () => ({
  Turbo: { renderStreamMessage },
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
    renderStreamMessage.mockReset()
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
    expect(createSubscription).toHaveBeenCalledWith(
      { channel: 'Collavre::InboxBadgeChannel' },
      expect.objectContaining({ received: expect.any(Function) }),
    )
  })

  test('renders the transmitted badge snapshot through Turbo on its own subscription', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))

    const [, callbacks] = createSubscription.mock.calls[0]
    const snapshot = '<turbo-stream action="replace" target="desktop-inbox-badge"></turbo-stream>'
    callbacks.received(snapshot)

    expect(renderStreamMessage).toHaveBeenCalledWith(snapshot)
  })

  test('unsubscribes when the controller disconnects', async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))

    container.remove()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(subscription.unsubscribe).toHaveBeenCalledTimes(1)
  })
})
