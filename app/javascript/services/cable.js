import { createConsumer as actionCableCreateConsumer } from '@rails/actioncable'

let singletonConsumer

export function createConsumer(...args) {
  if (args.length > 0) {
    return actionCableCreateConsumer(...args)
  }

  if (!singletonConsumer) {
    singletonConsumer = actionCableCreateConsumer()
  }

  return singletonConsumer
}

export function resetConsumer() {
  if (singletonConsumer) {
    singletonConsumer.disconnect()
    singletonConsumer = null
  }
}

export default {
  createConsumer,
  resetConsumer,
}
