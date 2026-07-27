# frozen_string_literal: true

module CollavreGithub
  # Trims the webhook idempotency ledger. Rows are only useful for as long as
  # GitHub could still redeliver the same GUID; past that they are dead weight.
  class WebhookDeliveryPruneJob < ApplicationJob
    queue_as :default

    def perform
      deleted = CollavreGithub::WebhookDelivery.prune!
      Rails.logger.info("[CollavreGithub::WebhookDeliveryPruneJob] pruned #{deleted} rows") if deleted.positive?
    end
  end
end
