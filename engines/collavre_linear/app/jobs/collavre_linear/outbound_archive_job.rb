# frozen_string_literal: true

module CollavreLinear
  # Archives (soft-deletes) a Linear issue when the corresponding Collavre
  # Creative is destroyed.
  #
  # Usage:
  #   CollavreLinear::OutboundArchiveJob.perform_later(linear_issue_id, account_id)
  #
  # The linear_issue_id and account_id are captured BEFORE the creative row is
  # deleted (in CreativeSyncObserver#before_destroy) because after_commit on
  # destroy runs after the row — and its dependent IssueLink — are gone.
  class OutboundArchiveJob < ApplicationJob
    queue_as :default

    # Retries on transient Linear API errors.
    retry_on CollavreLinear::Client::Error, wait: :polynomially_longer, attempts: 5

    def perform(linear_issue_id, account_id)
      account = CollavreLinear::Account.find(account_id)
      client  = CollavreLinear::Client.new(account)
      client.archive_issue(linear_issue_id)
    rescue ActiveRecord::RecordNotFound
      Rails.logger.info(
        "[CollavreLinear::OutboundArchiveJob] Account #{account_id} not found; skipping archive for issue #{linear_issue_id}"
      )
    end
  end
end
