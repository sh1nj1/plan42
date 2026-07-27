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

    # Last path segment of the deprecated singular `post "webhook"` route. The
    # route still answers so that untouched repositories keep working, but a
    # hook pointing at it is redundant with the plural one, so provisioning
    # migrates the repository by deleting it. Derived from `webhook_url` at
    # runtime so the engine's mount point stays the single source of truth.
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
    #   :secret_aligned  - non-primary link with existing hook; the local
    #                      RepositoryLink secret was aligned and the hook itself
    #                      was neither created nor patched. NOT a local-only
    #                      operation: registration and legacy-hook cleanup still
    #                      run, so GitHub may be called and a hook deleted. In
    #                      particular the hook's event list is left untouched —
    #                      see `provision_hook`.
    #   :shared          - a hook registered in THIS database already exists, so
    #                      another instance of this app owns it. No hook of this
    #                      instance's own remains: a second one would make GitHub
    #                      deliver every event twice. Its events and secret are
    #                      refreshed, but its URL is left alone — rewriting that
    #                      would break the sibling and start a rewrite war
    #                      between the two. Also reported when this run created a
    #                      hook, lost the registration race to a sibling doing
    #                      the same concurrently, and deleted the hook it made.
    #   :failed          - Octokit/Faraday error OR Client returned nil
    def ensure_for_links(links)
      links.map { |link| [ link, ensure_webhook(link) ] }
    end

    def remove_for_repositories(repositories)
      # Batch-query to avoid N+1: find all repo names that still have links.
      # Compared case-insensitively — see `links_for`. Matching exactly would
      # miss a surviving link stored under different casing and tear down a
      # hook the repository still needs.
      names = repositories.map { |name| normalize_repository_name(name) }
      linked_names = CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) IN (?)", names)
        .distinct
        .pluck(:repository_full_name)
        .map { |name| normalize_repository_name(name) }
        .to_set

      repositories.each do |repository_full_name|
        next if linked_names.include?(normalize_repository_name(repository_full_name))

        remove_webhook(repository_full_name)
      end
    end

    private

    attr_reader :client, :webhook_url

    def ensure_webhook(link)
      repository_full_name = link.repository_full_name
      primary_link = primary_link_for(repository_full_name)
      hooks = repository_hooks(repository_full_name)
      # Read before provisioning, because registering the replacement overwrites
      # it — and for a legacy hook under another host it is the only evidence
      # that the hook belongs to a deployment sharing this database, which is
      # what makes it ours to migrate.
      prior_registration = registered_hook_id(repository_full_name)
      hook = find_own_hook(hooks)
      shared = find_shared_hook(hooks, repository_full_name, hook)

      if shared && hook
        # A leftover from before hooks were registered: this instance owns one
        # and a sibling owns another, both feeding this database. Inbound
        # deliveries are already deduplicated by GUID, so the extra hook only
        # wastes bandwidth — not enough to justify deleting a live hook out
        # from under whoever created it, but worth surfacing.
        Rails.logger.warn(
          "[CollavreGithub] #{repository_full_name} carries both this instance's hook " \
          "#{hook_url(hook)} and registered hook #{hook_url(shared)}; delete one to stop " \
          "GitHub sending every delivery twice"
        )
      end

      status = provision_hook(link, repository_full_name, primary_link, hooks, hook, shared)

      # Deliberately AFTER a replacement is in place. Deleting first left the
      # repository with no hook at all whenever the create that followed failed
      # — a transient GitHub error was enough — and callers report success
      # regardless, so events stopped until provisioning happened to run again.
      # Keeping the legacy hook on failure costs at most a duplicate delivery,
      # which the GUID ledger already collapses.
      delete_legacy_hooks(repository_full_name, hooks, prior_registration) unless status == :failed

      status
    rescue Octokit::Error => e
      Rails.logger.warn(
        "GitHub webhook provisioning failed for #{repository_full_name}: #{e.message}"
      )
      :failed
    end

    def provision_hook(link, repository_full_name, primary_link, hooks, hook, shared)
      if hook
        register_hook(repository_full_name, hook.id, hooks)

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

        if shared
          # Registered in this database, so the instance that created it reads
          # the same RepositoryLink rows: same signing secret, same event list
          # (`events_for` queries those rows). Reusing it is safe and is the
          # only way to keep exactly one hook per repo.
          #
          # Its subscriptions are still refreshed. `events_for` widens to
          # include `push` the moment any link enables markdown sync, and the
          # sibling that owns the hook has no reason to reprovision — leaving
          # it on the old list would let the initial sync run and then silently
          # miss every later push. Only the URL is preserved: rewriting that to
          # this host would break the sibling and start the two instances
          # flipping it back and forth.
          Rails.logger.info(
            "[CollavreGithub] reusing registered hook #{hook_url(shared)} " \
            "for #{repository_full_name}; not creating #{webhook_url}"
          )
          return update_shared_webhook(repository_full_name, shared, secret) ? :shared : :failed
        end

        created = create_webhook(repository_full_name, secret)
        return :failed unless created

        created_id = created_hook_id(created)
        # No id to register with (a Client that swallowed the error): the hook
        # may well exist, so registration is deferred to the next run, which
        # finds it by URL. Nothing to undo either way.
        return :created if created_id.blank?
        return :created if register_hook(repository_full_name, created_id, hooks)

        # A sibling instance created and registered its own hook while this one
        # was creating its own. Both feed this database, so keeping both would
        # double every delivery for good.
        discard_duplicate_hook(repository_full_name, created_id)
        :shared
      end
    end

    def remove_webhook(repository_full_name)
      hooks = repository_hooks(repository_full_name)
      delete_legacy_hooks(repository_full_name, hooks)

      hook = find_own_hook(hooks)
      if hook
        client.delete_repository_webhook(repository_full_name, hook.id)
      end

      # Only this instance's own hook is deleted. The registration that would
      # identify a sibling lives on the repository's links, and this method
      # only runs once the last of them is gone, so there is no longer any
      # evidence of who created the remaining hooks. A hook on the same path
      # under a different host may equally be a sibling instance or a separate
      # deployment with its own database, for which this unlink says nothing —
      # deleting it would silently break that deployment. It is reported, not
      # removed.
      leftover = find_same_path_hook(hooks)
      if leftover
        Rails.logger.info(
          "[CollavreGithub] hook #{hook_url(leftover)} on #{repository_full_name} was left in " \
          "place after unlink: its owner cannot be determined once the links are gone. " \
          "Delete it manually if no deployment still needs it"
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

    # A hook another instance of this app created, identified by the id it
    # recorded on this repository's links.
    #
    # Registration is the only positive evidence of shared state, and that is
    # what makes reuse safe. Matching on the URL path instead would classify a
    # completely separate deployment's hook as reusable merely because it
    # serves the same path — that deployment has its own database and its own
    # webhook secret, so deferring to it would leave this instance receiving no
    # deliveries at all. Matching on the full URL is the opposite failure and is
    # the proliferation this fix targets: every instance saw its siblings' hooks
    # as foreign and created its own, so N instances meant N hooks.
    #
    # `own_hook` is excluded so callers can distinguish "mine" from "theirs"
    # when this instance is itself the registered owner.
    #
    # A hook on the legacy path is excluded too, however it came to be
    # registered. This run deletes it, so reusing it as the replacement means
    # patching it, reporting success, and then deleting the only hook the
    # repository had — no replacement was ever created because this branch
    # said one already existed.
    def find_shared_hook(hooks, repository_full_name, own_hook)
      registered = registered_hook_id(repository_full_name)
      return nil if registered.blank?

      hooks.find do |hook|
        hook.id.to_s == registered.to_s &&
          (own_hook.nil? || hook.id != own_hook.id) &&
          !legacy_hook?(hook)
      end
    end

    # Hooks this run will migrate off the deprecated singular path. Blank
    # `legacy_webhook_path` (an unexpected `webhook_url`) matches nothing, so
    # no hook is ever reclassified on a guess.
    def legacy_hook?(hook)
      return false if legacy_webhook_path.blank?

      url_path(hook_url(hook)) == legacy_webhook_path
    end

    # Reporting only — never a reuse decision. See `remove_webhook`.
    def find_same_path_hook(hooks)
      hooks.find do |hook|
        url = hook_url(hook)
        url != webhook_url && url_path(url) == webhook_path
      end
    end

    # Every single-repository link lookup in this class goes through here
    # (`remove_for_repositories` batches many names and normalizes them the same
    # way inline). GitHub treats
    # `owner/repo` case-insensitively and serves one repository — and one set of
    # hooks — regardless of the spelling used, but `repository_full_name` is
    # stored verbatim from whatever the caller supplied. Two creatives linking
    # the same repository with different casing therefore produce link rows an
    # exact match cannot see across, which would hide the registered hook id and
    # let the next run create a second hook: precisely the proliferation this
    # class exists to prevent. The webhook controller and pr_monitor already
    # compare with `LOWER(repository_full_name)`; this matches them.
    def links_for(repository_full_name)
      CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", normalize_repository_name(repository_full_name))
    end

    def normalize_repository_name(repository_full_name)
      repository_full_name.to_s.downcase
    end

    def registered_hook_id(repository_full_name)
      links_for(repository_full_name)
        .where.not(webhook_hook_id: nil)
        .order(:id)
        .pick(:webhook_hook_id)
    end

    # Records the hook so sibling instances can recognise it. Written to every
    # link for the repository, not just the primary one, so that deleting a
    # link cannot lose the registration and let the next run create a duplicate.
    #
    # Skipped while the registered hook is still live on GitHub: overwriting a
    # sibling's registration would let the two instances take turns claiming it
    # and bring the proliferation straight back. A registration whose hook has
    # since been deleted is stale and gets replaced.
    #
    # Returns whether this database's registration ends up naming `hook_id`.
    # The caller needs that answer because the read above and the write below
    # are not one operation: two instances provisioning the same repository at
    # once both list no hooks, both create one, and both arrive here. The write
    # is therefore a compare-and-set against the value just read, so only one
    # can win — the loser's UPDATE matches nothing, because the row it is
    # testing against has already moved. Without it the two writes were plain
    # last-writer-wins and both hooks stayed live forever.
    def register_hook(repository_full_name, hook_id, hooks)
      return false if hook_id.blank?

      registered = registered_hook_id(repository_full_name)
      if registered.to_s == hook_id.to_s
        backfill_registration(repository_full_name, hook_id)
        return true
      end
      live = live_registered_hook(repository_full_name, registered, hooks)
      # A live registration naming a LEGACY hook is not a competitor to defer
      # to: this run is replacing that hook, not racing a sibling for it.
      # Deferring would discard the replacement just created and then delete the
      # legacy hook, leaving the repository with none at all.
      return false if live && !legacy_hook?(live)

      links_for(repository_full_name)
        .where(webhook_hook_id: [ nil, registered ].uniq)
        .update_all(webhook_hook_id: hook_id)

      # Re-read rather than trust the affected-row count: the rows are only
      # "ours" if the registration now reads back as this hook.
      registered_hook_id(repository_full_name).to_s == hook_id.to_s
    end

    # A link created after the hook was registered starts with a null
    # webhook_hook_id, and the compare-and-set above returns before writing
    # anything — the value it compares against is already correct, so there is
    # nothing to set. That leaves the registration on the older links only.
    # Removing those links then takes the last copy of it with them, and the
    # live hook becomes unrecognisable: `find_shared_hook` requires a recorded
    # id, so the next run from a sibling host reads it as foreign and adds a
    # second hook — the proliferation this registry exists to stop.
    #
    # Only null registrations are filled. A link naming a different hook is not
    # this run's to overwrite; that case is the stale-vs-live question the CAS
    # above already answers.
    def backfill_registration(repository_full_name, hook_id)
      links_for(repository_full_name)
        .where(webhook_hook_id: nil)
        .update_all(webhook_hook_id: hook_id)
    end

    # The registered hook as it exists on GitHub, or nil if it is gone.
    #
    # `hooks` was listed before this run started creating anything, so a
    # registration missing from it is NOT proof the hook is gone — a sibling
    # instance may have created and registered it since. The two cases demand
    # opposite actions (replace a stale registration; defer to a live one) and
    # getting either wrong puts a second hook on the repository, so when the
    # cached listing cannot vouch for it the question is put to GitHub.
    #
    # The hook itself is returned rather than a boolean: the caller also has to
    # know whether it sits on the legacy path, which only its URL can say.
    def live_registered_hook(repository_full_name, registered, hooks)
      # Nothing registered, so there is no hook to vouch for and the re-listing
      # below could only ever come back empty. Skipping it matters because this
      # is the ordinary first provision of a repository, where paying for a
      # second GitHub round trip buys nothing.
      return nil if registered.blank?

      found = hooks.find { |hook| hook.id.to_s == registered.to_s }
      return found if found

      repository_hooks(repository_full_name).find { |hook| hook.id.to_s == registered.to_s }
    end

    # Undoes a hook this run created after losing the registration race above.
    # Leaving it would put two live hooks on the repository permanently — the
    # next run sees one registered hook and one of its own and can only warn,
    # since deleting a hook it cannot prove it created is unsafe. Here that
    # proof exists: this run created this hook seconds ago.
    #
    # A failure to delete is logged rather than raised. The hook is real and
    # working, so the cost is a duplicate delivery, which the GUID ledger
    # already collapses — not worth failing an otherwise successful provision.
    def discard_duplicate_hook(repository_full_name, hook_id)
      Rails.logger.info(
        "[CollavreGithub] deleting hook #{hook_id} just created for #{repository_full_name}: " \
        "another instance registered its own hook concurrently"
      )
      client.delete_repository_webhook(repository_full_name, hook_id)
    rescue Octokit::Error => e
      Rails.logger.warn(
        "[CollavreGithub] could not delete redundant hook #{hook_id} on " \
        "#{repository_full_name}: #{e.message}. Delete it manually to stop GitHub " \
        "sending every delivery twice"
      )
    end

    # Octokit returns the created hook; a Client that swallowed the error
    # returns something without an id, in which case registration is simply
    # deferred to the next run, which finds the hook by URL.
    def created_hook_id(created)
      created.id if created.respond_to?(:id)
    end

    # Migrates the repository off the deprecated singular `/github/webhook`
    # path: alongside the plural hook it only produces a duplicate delivery,
    # and removing it here is what eventually makes the alias route droppable.
    def delete_legacy_hooks(repository_full_name, hooks, prior_registration = nil)
      return if legacy_webhook_path.blank?

      registered = [ prior_registration, registered_hook_id(repository_full_name) ]
        .compact_blank
        .map(&:to_s)
      legacy = hooks.select { |hook| legacy_hook?(hook) }
      mine, theirs = legacy.partition { |hook| own_legacy_hook?(hook, registered) }

      theirs.each do |hook|
        Rails.logger.info(
          "[CollavreGithub] leaving legacy hook #{hook_url(hook)} on #{repository_full_name} " \
          "in place: it is not registered here and sits under another host, so it may belong " \
          "to an independent deployment still served by that route"
        )
      end

      mine.each do |hook|
        Rails.logger.info(
          "[CollavreGithub] deleting legacy hook #{hook_url(hook)} on #{repository_full_name}"
        )
        delete_legacy_hook(repository_full_name, hook)
      end
    end

    # Rescued for the same reason `discard_duplicate_hook` is: by the time this
    # runs the replacement hook is already in place, so a failure to remove the
    # deprecated one costs a duplicate delivery that the GUID ledger collapses.
    # Letting it escape reaches `ensure_webhook`'s `rescue Octokit::Error` and
    # turns a provision that actually succeeded into `:failed`, which
    # `pr_monitor` reports as "GitHub API rejected the hook request" — a false
    # alarm about the very hook that was just provisioned correctly.
    #
    # Defence in depth rather than a live bug: the injected production client
    # (`CollavreGithub::Client`) rescues Octokit and Faraday itself and answers
    # nil, so nothing raises this far today. That also makes the outer rescue
    # unreachable in production, which is precisely why the cost of an
    # unrescued raise here is invisible until a client that does raise is used.
    def delete_legacy_hook(repository_full_name, hook)
      client.delete_repository_webhook(repository_full_name, hook.id)
    rescue Octokit::Error => e
      Rails.logger.warn(
        "[CollavreGithub] could not delete legacy hook #{hook_url(hook)} on " \
        "#{repository_full_name}: #{e.message}. It is redundant with the plural-path " \
        "hook; delete it manually to stop GitHub sending every delivery twice"
      )
    end

    # Deletion must rest on stronger evidence than reuse, not weaker. Matching
    # the legacy PATH alone would delete the hook of an independent deployment
    # that still serves `/github/webhook` — a supported route — and take its
    # deliveries offline. Ownership is therefore positive: either the hook
    # carries this instance's own host, or its id is registered in this
    # database, which only an instance sharing this database could have written.
    def own_legacy_hook?(hook, registered_ids)
      return true if registered_ids.include?(hook.id.to_s)

      same_origin?(hook_url(hook), webhook_url)
    end

    def same_origin?(url, other)
      a = URI.parse(url)
      b = URI.parse(other)
      a.host.present? && a.host == b.host && a.port == b.port
    rescue URI::InvalidURIError
      false
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

    # Refreshes a sibling instance's hook while leaving its URL alone, so the
    # deliveries keep flowing to whichever host created it.
    def update_shared_webhook(repository_full_name, hook, secret)
      client.update_repository_webhook(
        repository_full_name,
        hook.id,
        url: hook_url(hook),
        secret: secret,
        events: events_for(repository_full_name),
        content_type: CONTENT_TYPE
      )
    end

    def events_for(repository_full_name)
      has_markdown_sync = links_for(repository_full_name)
        .where(markdown_sync_enabled: true)
        .exists?
      has_markdown_sync ? EVENTS_WITH_PUSH : EVENTS
    end

    def primary_link_for(repository_full_name)
      links_for(repository_full_name).order(:id).first
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
