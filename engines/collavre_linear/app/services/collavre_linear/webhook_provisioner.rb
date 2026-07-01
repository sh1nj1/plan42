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
      # Idempotent: this link is already provisioned — nothing to do.
      return :skipped if @project_link.webhook_id.present?

      # A sibling for the same team already has a webhook; adopt its id + secret.
      if (existing = existing_team_webhook)
        # Linear signs ALL deliveries for a team with the single secret it was
        # registered with. WebhooksController#find_project_link can resolve a
        # delivery to any sibling link for the team, so every sibling MUST carry
        # the SAME webhook_secret (and id) or HMAC verification 401s. Copy both.
        adopt_team_webhook(existing)
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
    #
    # Webhooks are team-scoped/shared: siblings for the same team reuse the same
    # webhook_id. Only delete the remote webhook when NO OTHER ProjectLink for
    # the team still references it — otherwise unlinking one project would kill
    # inbound sync for every remaining sibling.
    def deregister
      webhook_id = @project_link.webhook_id
      return if webhook_id.blank?

      unless siblings_share_webhook?(webhook_id)
        client.delete_webhook(webhook_id)
      end

      @project_link.update_column(:webhook_id, nil)
    rescue CollavreLinear::Client::Error => e
      Rails.logger.warn(
        "[CollavreLinear::WebhookProvisioner] Webhook deregistration failed for " \
        "webhook #{webhook_id}: #{e.message}"
      )
    end

    private

    attr_reader :project_link, :webhook_url

    def client
      @client ||= CollavreLinear::Client.new(@project_link.account)
    end

    # Copy the existing team webhook's id AND secret onto this link so every
    # sibling for the team shares the single secret Linear signs with.
    def adopt_team_webhook(existing)
      updates = {}
      updates[:webhook_id]     = existing.webhook_id     if @project_link.webhook_id.blank?
      updates[:webhook_secret] = existing.webhook_secret if existing.webhook_secret.present?
      return if updates.empty?

      @project_link.update_columns(updates)
    end

    # The first sibling ProjectLink (any team member) that already carries a
    # webhook_id, used as the source of the shared id + secret.
    def existing_team_webhook
      CollavreLinear::ProjectLink
        .where(team_id: @project_link.team_id)
        .where.not(id: @project_link.id)
        .where.not(webhook_id: [ nil, "" ])
        .first
    end

    # True when another ProjectLink for the same team still references webhook_id.
    def siblings_share_webhook?(webhook_id)
      CollavreLinear::ProjectLink
        .where(team_id: @project_link.team_id, webhook_id: webhook_id)
        .where.not(id: @project_link.id)
        .exists?
    end
  end
end
