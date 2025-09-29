import livestoreClient from './api/livestore.client';

if (!window.creativeUpdatesStreamInitialized) {
  window.creativeUpdatesStreamInitialized = true;

  const ensureConsumer = () => {
    if (window.creativeUpdatesConsumer) return window.creativeUpdatesConsumer;
    if (!window.ActionCable || !window.ActionCable.createConsumer) return null;
    window.creativeUpdatesConsumer = window.ActionCable.createConsumer();
    return window.creativeUpdatesConsumer;
  };

  const subscribe = () => {
    if (!livestoreClient.isEnabled()) return;
    const consumer = ensureConsumer();
    if (!consumer) return;

    if (window.creativeUpdatesSubscription) {
      window.creativeUpdatesSubscription.unsubscribe();
    }

    window.creativeUpdatesSubscription = consumer.subscriptions.create(
      { channel: 'CreativeUpdatesChannel' },
      {
        received(data) {
          if (!data || !data.id) return;
          if (data.event === 'destroy') {
            livestoreClient.removeCachedCreative(data.id);
          } else {
            livestoreClient.refreshFromServer(data.id);
          }
        },
      },
    );
  };

  document.addEventListener('turbo:load', subscribe);
}
