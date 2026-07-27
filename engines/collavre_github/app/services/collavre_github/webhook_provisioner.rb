module CollavreGithub
  class WebhookProvisioner
    # PR channel webhooks need every event GithubPrChannel handles. Without
    # `issue_comment` / `pull_request_review` / `pull_request_review_comment`
    # GitHub never delivers the relevant deliveries, so pr_monitor would attach
    # a channel that silently misses comments. `pull_request` is required by
    # the auto-attach + close detection paths.
    CHANNEL_EVENTS = %w[issue_comment pull_request_review pull_request_review_comment].freeze
    EVENTS = (%w[pull_request] + CHANNEL_EVENTS).freeze
    EVENTS_WITH_PUSH = (%w[pull_request push] + CHANNEL_EVENTS).freeze
    CONTENT_TYPE = "json".freeze

    # Last path segment of the removed singular `post "webhook"` route. Any hook
    # still pointing at it is dead and only amplifies deliveries, so it is
    # deleted during provisioning. Derived from `webhook_url` at runtime so the
    # engine's mount point stays the single source of truth.
    LEGACY_ROUTE_SEGMENT = "webhook".freeze
    ROUTE_SEGMENT = "webhooks".freeze

    def self.ensure_for_links(account:, links:, webhook_url:)
      new(account: account, webhook_url: webhook_url).ensure_for_links(Array(links))
    end

    def self.remove_for_repositories(account:, repositories:, webhook_url:)
      new(account: account, webhook_url: webhook_url).remove_for_repositories(Array(repositories))
    end

    def initialize(account:, webhook_url:, client: CollavreGithub::Client.new(account))
      @client = client
      @webhook_url = webhook_url
    end

    # Returns [[link, status], ...] so callers can detect silent GitHub
    # rejections. status is one of:
    #   :created         - new hook created
    #   :updated         - existing hook patched (events/url/secret)
    #   :secret_aligned  - non-primary link with existing hook; only the local
    #                      RepositoryLink secret was aligned. No GitHub call.
    #   :shared          - another instance of this app already owns a hook on
    #                      the webhook path under a different host. Nothing was
    #                      created or edited: creating a second hook would make
    #                      GitHub deliver every event twice, and rewriting the
    #                      sibling's URL would break that instance (and start a
    #                      rewrite war between the two).
    #   :failed          - Octokit/Faraday error OR Client returned nil
    def ensure_for_links(links)
      links.map { |link| [ link, ensure_webhook(link) ] }
    end

    def remove_for_repositories(repositories)
      # Batch-query to avoid N+1: find all repo names that still have links
      linked_names = CollavreGithub::RepositoryLink
        .where(repository_full_name: repositories)
        .distinct
        .pluck(:repository_full_name)
        .to_set

      repositories.each do |repository_full_name|
        next if linked_names.include?(repository_full_name)

        remove_webhook(repository_full_name)
      end
    end

    private

    attr_reader :client, :webhook_url

    def ensure_webhook(link)
      repository_full_name = link.repository_full_name
      primary_link = primary_link_for(repository_full_name)
      hooks = repository_hooks(repository_full_name)
      delete_legacy_hooks(repository_full_name, hooks)
      hook = find_own_hook(hooks)

      if hook
        if primary_link && primary_link != link
          align_link_secret(link, primary_link.webhook_secret)
          :secret_aligned
        else
          update_webhook(repository_full_name, hook.id, link.webhook_secret) ? :updated : :failed
        end
      else
        secret = link.webhook_secret

        if primary_link && primary_link != link
          secret = primary_link.webhook_secret
          align_link_secret(link, secret)
        end

        sibling = find_sibling_hook(hooks)
        if sibling
          # The sibling was created by an instance sharing this database, so it
          # signs with the same RepositoryLink secret and subscribes to the same
          # event list (`events_for` reads the same rows). Reusing it is safe and
          # is the only way to keep exactly one hook per repo.
          Rails.logger.info(
            "[CollavreGithub] reusing existing #{webhook_path} hook #{hook_url(sibling)} " \
            "for #{repository_full_name}; not creating #{webhook_url}"
          )
          return :shared
        end

        create_webhook(repository_full_name, secret) ? :created : :failed
      end
    rescue Octokit::Error => e
      Rails.logger.warn(
        "GitHub webhook provisioning failed for #{repository_full_name}: #{e.message}"
      )
      :failed
    end

    def remove_webhook(repository_full_name)
      hooks = repository_hooks(repository_full_name)
      delete_legacy_hooks(repository_full_name, hooks)

      hook = find_own_hook(hooks)
      if hook
        client.delete_repository_webhook(repository_full_name, hook.id)
      end

      # Siblings are NOT deleted. A hook on the same path under a different host
      # usually belongs to another instance of this app — but it may belong to a
      # separate deployment with its own database, for which this unlink says
      # nothing. Deleting it would silently break that deployment, so log it
      # instead of guessing.
      sibling = find_sibling_hook(hooks)
      if sibling
        Rails.logger.info(
          "[CollavreGithub] left sibling hook #{hook_url(sibling)} on #{repository_full_name} " \
          "in place after unlink; delete it manually if it is no longer in use"
        )
      end
    rescue Octokit::Error => e
      Rails.logger.warn(
        "GitHub webhook removal failed for #{repository_full_name}: #{e.message}"
      )
    end

    def repository_hooks(repository_full_name)
      Array(client.repository_hooks(repository_full_name))
    end

    def find_own_hook(hooks)
      hooks.find { |hook| hook_url(hook) == webhook_url }
    end

    # A hook on the webhook path under some other host: another instance of this
    # app. Excludes our own URL so callers can distinguish "mine" from "theirs".
    #
    # Matching on PATH rather than full URL is the fix for hook proliferation:
    # full-URL matching made every instance sharing a database see its siblings'
    # hooks as foreign and create its own, so N instances meant N hooks and
    # GitHub fanned every delivery out N times.
    def find_sibling_hook(hooks)
      hooks.find do |hook|
        url = hook_url(hook)
        url != webhook_url && url_path(url) == webhook_path
      end
    end

    # The singular `/github/webhook` route no longer exists, so these hooks can
    # only produce 404s — and, until GitHub disables them, duplicate deliveries
    # alongside the plural hook. Removing them is the point of the cleanup.
    def delete_legacy_hooks(repository_full_name, hooks)
      return if legacy_webhook_path.blank?

      hooks.select { |hook| url_path(hook_url(hook)) == legacy_webhook_path }.each do |hook|
        Rails.logger.info(
          "[CollavreGithub] deleting legacy hook #{hook_url(hook)} on #{repository_full_name}"
        )
        client.delete_repository_webhook(repository_full_name, hook.id)
      end
    end

    def webhook_path
      @webhook_path ||= url_path(webhook_url)
    end

    # `/github/webhooks` -> `/github/webhook`. Blank when `webhook_url` does not
    # end in the expected segment, so an unexpected URL never causes an
    # unrelated hook to be deleted.
    def legacy_webhook_path
      return @legacy_webhook_path if defined?(@legacy_webhook_path)

      @legacy_webhook_path =
        if webhook_path.end_with?("/#{ROUTE_SEGMENT}")
          webhook_path.sub(/#{Regexp.escape(ROUTE_SEGMENT)}\z/, LEGACY_ROUTE_SEGMENT)
        end
    end

    def hook_url(hook)
      normalize_config(hook.config)["url"].to_s
    end

    # Trailing slashes are insignificant to Rails routing but not to string
    # comparison, so normalize them away before matching.
    def url_path(url)
      path = URI.parse(url).path.to_s
      path = path.chomp("/") if path.length > 1
      path
    rescue URI::InvalidURIError
      ""
    end

    def create_webhook(repository_full_name, secret)
      client.create_repository_webhook(
        repository_full_name,
        url: webhook_url,
        secret: secret,
        events: events_for(repository_full_name),
        content_type: CONTENT_TYPE
      )
    end

    def update_webhook(repository_full_name, hook_id, secret)
      client.update_repository_webhook(
        repository_full_name,
        hook_id,
        url: webhook_url,
        secret: secret,
        events: events_for(repository_full_name),
        content_type: CONTENT_TYPE
      )
    end

    def events_for(repository_full_name)
      has_markdown_sync = CollavreGithub::RepositoryLink
        .where(repository_full_name: repository_full_name, markdown_sync_enabled: true)
        .exists?
      has_markdown_sync ? EVENTS_WITH_PUSH : EVENTS
    end

    def primary_link_for(repository_full_name)
      CollavreGithub::RepositoryLink
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
