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
      links = CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", repository_name)
        .order(:id)
        .to_a
      failed = false

      links.each do |candidate|
        unless candidate.github_account
          failed = true
          next
        end

        link = establish_repository_identity(candidate)
        next unless link

        result = CollavreGithub::WebhookProvisioner.ensure_for_links(
          account: link.github_account,
          links: [ link ],
          webhook_url: webhook_url
        )
        return result.first&.last || :failed
      rescue => e
        failed = true
        log_failure(repository_name, e)
      end

      failed ? :failed : :skipped_unverified
    end

    def log_failure(repository_name, error)
      Rails.logger.warn(
        "[CollavreGithub::WebhookReprovisioner] #{repository_name} failed: " \
        "#{error.class}: #{error.message}"
      )
    end

    def establish_repository_identity(link)
      client = CollavreGithub::Client.new(link.github_account)
      if link.repository_id.blank?
        return if link.webhook_hook_id.blank?

        hook_ids = client.repository_hooks!(link.repository_full_name).map { |hook| hook.id.to_s }
        return unless hook_ids.include?(link.webhook_hook_id.to_s)
      end

      identity = client.repository_identity(link.repository_full_name)
      return if identity&.id.blank? || identity&.full_name.blank?
      return if link.repository_id.present? && link.repository_id.to_s != identity.id.to_s

      synchronized = CollavreGithub::RepositoryIdentitySynchronizer.call(
        anchor: link,
        repository_id: identity.id,
        full_name: identity.full_name,
        trusted_hook_id: link.webhook_hook_id,
        trusted_secret: link.webhook_secret
      )
      synchronized.find { |candidate| candidate.creative_id == link.creative_id }
    end
  end
end
