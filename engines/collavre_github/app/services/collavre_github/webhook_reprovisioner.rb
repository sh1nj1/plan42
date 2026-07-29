module CollavreGithub
  # Reconciles every ID-backed repository hook with WebhookProvisioner's current
  # event list. New event subscriptions in code do not change hooks already
  # stored at GitHub, so deploys run this once after the new app is live.
  #
  # Name-only legacy rows are never mutated automatically. Older provisioners
  # copied a hook registration and secret to every same-name row, so neither
  # value is independent proof that a legacy row belongs to the repository
  # currently owning that name. Their presence is reported as requiring manual
  # verification so deploys cannot silently leave them unreconciled.
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
      manual_verification_required = links.any? { |link| link.repository_id.blank? }
      failed = false

      links.select { |link| link.repository_id.present? }.each do |candidate|
        repository_id = candidate.repository_id
        status = CollavreGithub::RepositoryProvisioningLock.with_lock(repository_id) do
          locked_candidate = CollavreGithub::RepositoryLink.find_by(
            id: candidate.id,
            repository_id: repository_id
          )
          next :skipped_unverified unless locked_candidate
          next :failed unless locked_candidate.github_account

          link = establish_repository_identity(locked_candidate)
          next :skipped_unverified unless link

          result = CollavreGithub::WebhookProvisioner.ensure_for_links(
            account: link.github_account,
            links: [ link ],
            webhook_url: webhook_url,
            force_hook_refresh: true
          )
          result.first&.last || :failed
        end

        if status == :failed
          failed = true
          next
        end
        next if status == :skipped_unverified

        return :manual_verification_required if manual_verification_required

        return status
      rescue => e
        failed = true
        log_failure(repository_name, e)
      end

      return :failed if failed
      return :manual_verification_required if manual_verification_required

      :skipped_unverified
    end

    def log_failure(repository_name, error)
      Rails.logger.warn(
        "[CollavreGithub::WebhookReprovisioner] #{repository_name} failed: " \
        "#{error.class}: #{error.message}"
      )
    end

    def establish_repository_identity(link)
      return if link.repository_id.blank?

      client = CollavreGithub::Client.new(link.github_account)
      identity = client.repository_identity(link.repository_full_name)
      return if identity&.id.blank? || identity&.full_name.blank?
      return if link.repository_id.to_s != identity.id.to_s

      synchronized = CollavreGithub::RepositoryIdentitySynchronizer.call(
        anchor: link,
        repository_id: identity.id,
        full_name: identity.full_name
      )
      synchronized.find { |candidate| candidate.creative_id == link.creative_id }
    end
  end
end
