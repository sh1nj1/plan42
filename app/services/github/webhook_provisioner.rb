module Github
  class WebhookProvisioner
    EVENTS = %w[pull_request].freeze
    CONTENT_TYPE = "json".freeze

    def self.ensure_for_links(account:, links:, webhook_url:)
      new(account: account, webhook_url: webhook_url).ensure_for_links(Array(links))
    end

    def initialize(account:, webhook_url:, client: Github::Client.new(account))
      @client = client
      @webhook_url = webhook_url
    end

    def ensure_for_links(links)
      links.each do |link|
        ensure_webhook(link)
      end
    end

    private

    attr_reader :client, :webhook_url

    def ensure_webhook(link)
      repository_full_name = link.repository_full_name
      hook = find_existing_hook(repository_full_name)

      if hook
        primary_link = primary_link_for(repository_full_name)

        if primary_link && primary_link != link
          align_link_secret(link, primary_link.webhook_secret)
        else
          update_webhook(repository_full_name, hook.id, link.webhook_secret)
        end
      else
        create_webhook(repository_full_name, link.webhook_secret)
      end
    rescue Octokit::Error => e
      Rails.logger.warn(
        "GitHub webhook provisioning failed for #{repository_full_name}: #{e.message}"
      )
    end

    def find_existing_hook(repository_full_name)
      client.repository_hooks(repository_full_name).find do |hook|
        config = normalize_config(hook.config)
        config["url"] == webhook_url
      end
    end

    def create_webhook(repository_full_name, secret)
      client.create_repository_webhook(
        repository_full_name,
        url: webhook_url,
        secret: secret,
        events: EVENTS,
        content_type: CONTENT_TYPE
      )
    end

    def update_webhook(repository_full_name, hook_id, secret)
      client.update_repository_webhook(
        repository_full_name,
        hook_id,
        url: webhook_url,
        secret: secret,
        events: EVENTS,
        content_type: CONTENT_TYPE
      )
    end

    def primary_link_for(repository_full_name)
      GithubRepositoryLink
        .where(repository_full_name: repository_full_name)
        .order(:id)
        .first
    end

    def align_link_secret(link, secret)
      return if secret.blank? || link.webhook_secret == secret

      link.update!(webhook_secret: secret)
    end

    def normalize_config(config)
      hash =
        case config
        when Hash
          config
        else
          config.respond_to?(:to_h) ? config.to_h : {}
        end

      hash.with_indifferent_access
    end
  end
end
