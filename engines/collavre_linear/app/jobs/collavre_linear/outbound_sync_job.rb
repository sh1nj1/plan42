# frozen_string_literal: true

module CollavreLinear
  # Enqueues an outbound sync for a single Creative to Linear.
  #
  # Usage:
  #   CollavreLinear::OutboundSyncJob.perform_later(creative.id)
  #
  # The critical section is guarded with a row-level lock on the IssueLink (or
  # the ProjectLink's creative row when no IssueLink exists yet) so concurrent
  # performs cannot double-create issues.
  class OutboundSyncJob < ApplicationJob
    queue_as :default

    # Retries on transient Linear API errors.
    retry_on CollavreLinear::Client::Error, wait: :polynomially_longer, attempts: 5

    def perform(creative_id)
      creative = ::Collavre::Creative.find(creative_id)

      # Resolve an existing IssueLink (or the creative itself) to lock on.
      # We lock the creative row so concurrent jobs serialize without racing to
      # create duplicate IssueLinks.
      creative.with_lock do
        CollavreLinear::CreativeExporter.new(creative).sync!
      end
    rescue ActiveRecord::RecordNotFound
      # Creative was deleted — nothing to sync.
      Rails.logger.info("[CollavreLinear::OutboundSyncJob] Creative #{creative_id} not found; skipping")
    end
  end
end
