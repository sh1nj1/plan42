module CollavreGithub
  # Reconciles every safely identifiable repository hook with
  # WebhookProvisioner's current event list. New event subscriptions in code do
  # not change hooks already stored at GitHub, so deploys run this once after
  # the new app is live. For a name-only legacy link, the stored hook id must
  # still exist under that name before the name is trusted: a stale name may
  # have been reused, but the unrelated repository cannot also own our hook id.
  class WebhookReprovisioner
    def self.call(webhook_url: default_webhook_url)
      new(webhook_url: webhook_url).call
    end

    def self.default_webhook_url
      CollavreGithub::Engine.routes.url_helpers.webhooks_url(
        Rails.application.config.action_mailer.default_url_options
      )
    end

    def initialize(webhook_url:)
      @webhook_url = webhook_url
    end

    def call
      repository_names.map do |repository_name|
        [ repository_name, reprovision(repository_name) ]
      end
    end

    private

    attr_reader :webhook_url

    def repository_names
      CollavreGithub::RepositoryLink
        .order(:id)
        .pluck(:repository_full_name)
        .filter_map { |name| name.to_s.downcase.presence }
        .uniq
        .sort
    end

    def reprovision(repository_name)
      link = CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", repository_name)
        .order(:id)
        .first
      return :failed unless link.github_account

      return :skipped_unverified unless establish_legacy_identity(link)

      result = CollavreGithub::WebhookProvisioner.ensure_for_links(
        account: link.github_account,
        links: [ link ],
        webhook_url: webhook_url
      )
      result.first&.last || :failed
    rescue => e
      Rails.logger.warn(
        "[CollavreGithub::WebhookReprovisioner] #{repository_name} failed: #{e.class}: #{e.message}"
      )
      :failed
    end

    def establish_legacy_identity(link)
      return true if link.repository_id.present?
      return false if link.webhook_hook_id.blank?

      client = CollavreGithub::Client.new(link.github_account)
      hook_ids = client.repository_hooks!(link.repository_full_name).map { |hook| hook.id.to_s }
      return false unless hook_ids.include?(link.webhook_hook_id.to_s)

      repository_id = client.repository_id(link.repository_full_name)
      return false if repository_id.blank?

      link.update_column(:repository_id, repository_id)
      true
    end
  end
end
