# frozen_string_literal: true

module CollavreLinear
  # Idempotent Linear webhook provisioner.
  #
  # Linear webhooks are scoped to a team. If any ProjectLink for the same
  # team already has a `webhook_id` stored we skip the API call (idempotent).
  # Otherwise we call `Client#register_webhook` and store the returned id on
  # the given project_link record.
  #
  # Usage:
  #   CollavreLinear::WebhookProvisioner.ensure_for(
  #     project_link: link,
  #     webhook_url:  "https://example.com/linear/webhook"
  #   )
  #   CollavreLinear::WebhookProvisioner.deregister(project_link: link)
  class WebhookProvisioner
    RESOURCE_TYPES = %w[Issue Project Comment].freeze

    # @param project_link [CollavreLinear::ProjectLink]
    # @param webhook_url  [String] public HTTPS URL Linear will POST to
    def self.ensure_for(project_link:, webhook_url:)
      new(project_link: project_link, webhook_url: webhook_url).ensure_for
    end

    # Best-effort deregistration of the webhook registered for project_link.
    # No-op when webhook_id is blank. Rescues Client::Error so that unlink
    # succeeds even if the Linear API call fails.
    #
    # @param project_link [CollavreLinear::ProjectLink]
    def self.deregister(project_link:)
      new(project_link: project_link, webhook_url: nil).deregister
    end

    def initialize(project_link:, webhook_url: nil)
      @project_link = project_link
      @webhook_url  = webhook_url
    end

    # Returns one of: :skipped, :created, :failed
    def ensure_for
      # Idempotent: if the team already has a webhook_id, skip.
      if team_already_has_webhook?
        # Copy the webhook_id to this link so it is consistent.
        existing_id = existing_webhook_id_for_team
        @project_link.update_column(:webhook_id, existing_id) if existing_id && @project_link.webhook_id.nil?
        return :skipped
      end

      webhook = client.register_webhook(
        url:            @webhook_url,
        secret:         @project_link.webhook_secret,
        team_id:        @project_link.team_id,
        resource_types: RESOURCE_TYPES
      )

      @project_link.update_column(:webhook_id, webhook[:id])
      :created
    rescue CollavreLinear::Client::Error => e
      Rails.logger.warn(
        "[CollavreLinear::WebhookProvisioner] Webhook registration failed for " \
        "team #{@project_link.team_id}: #{e.message}"
      )
      :failed
    end

    # Best-effort deregistration. No-op when webhook_id is blank.
    def deregister
      return unless @project_link.webhook_id.present?

      client.delete_webhook(@project_link.webhook_id)
    rescue CollavreLinear::Client::Error => e
      Rails.logger.warn(
        "[CollavreLinear::WebhookProvisioner] Webhook deregistration failed for " \
        "webhook #{@project_link.webhook_id}: #{e.message}"
      )
    end

    private

    attr_reader :project_link, :webhook_url

    def client
      @client ||= CollavreLinear::Client.new(@project_link.account)
    end

    def team_already_has_webhook?
      existing_webhook_id_for_team.present?
    end

    def existing_webhook_id_for_team
      CollavreLinear::ProjectLink
        .where(team_id: @project_link.team_id)
        .where.not(webhook_id: [ nil, "" ])
        .limit(1)
        .pick(:webhook_id)
    end
  end
end
