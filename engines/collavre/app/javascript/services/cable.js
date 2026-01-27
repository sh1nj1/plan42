import { createConsumer as actionCableCreateConsumer } from '@rails/actioncable'

let singletonConsumer

export function createConsumer(...args) {
  if (!singletonConsumer) {
    singletonConsumer = actionCableCreateConsumer(...args)
  } else if (args.length > 0) {
    console.warn(
      '[ActionCable] Ignoring createConsumer arguments because a singleton consumer already exists.',
    )
  }

  return singletonConsumer
}

export function createSubscription(identifier, callbacks = {}) {
  return createConsumer().subscriptions.create(identifier, callbacks)
}

export function resetConsumer() {
  if (singletonConsumer) {
    singletonConsumer.disconnect()
    singletonConsumer = null
  }
}

export default {
  createConsumer,
  createSubscription,
  resetConsumer,
}
