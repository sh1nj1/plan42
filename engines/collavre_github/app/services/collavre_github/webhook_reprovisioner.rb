module CollavreGithub
  # Reconciles every existing repository hook with WebhookProvisioner's current
  # event list. New event subscriptions in code do not change hooks already
  # stored at GitHub, so deploys run this once after the new app is live.
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
      return :failed unless link&.github_account

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
  end
end
