require_relative "../../test_helper"

module CollavreGithub
  class WebhookProvisionerTest < ActiveSupport::TestCase
    # `last_response` is what GitHub reports for the most recent delivery to a
    # hook. It rides along on every listing, so the provisioner has it without
    # asking for it.
    Hook = Struct.new(:id, :config, :last_response)

    # Records every call so tests can assert on what did NOT happen — the whole
    # point of the fix is that a second hook is never created.
    class FakeClient
      attr_reader :created, :updated, :deleted
      attr_accessor :hooks

      attr_accessor :repo_id

      def initialize(hooks: [], next_id: 100, repo_id: 555)
        @hooks = hooks
        @created = []
        @updated = []
        @deleted = []
        @next_id = next_id
        @repo_id = repo_id
      end

      # Mirrors Client#repository_id, which answers nil on any GitHub error.
      def repository_id(_repo)
        @repo_id
      end

      def repository_hooks(_repo)
        @hooks
      end

      def repository_hooks!(_repo)
        @hooks
      end

      # Mirrors Octokit, which answers with the created hook. The id is what the
      # provisioner records so sibling instances can recognise the hook.
      def create_repository_webhook(repo, url:, secret:, events:, content_type: "json")
        @created << { repo: repo, url: url, secret: secret, events: events }
        Hook.new(@next_id += 1, { "url" => url })
      end

      def update_repository_webhook(repo, hook_id, url:, secret:, events:, content_type: "json")
        @updated << { repo: repo, hook_id: hook_id, url: url, secret: secret, events: events }
        true
      end

      def delete_repository_webhook(repo, hook_id)
        @deleted << { repo: repo, hook_id: hook_id }
        true
      end
    end

    # A sibling instance that creates AND registers its own hook in the window
    # between this instance listing the repository's hooks and recording the one
    # it just created. Injected rather than sampled: that window is far too
    # narrow to hit reliably by racing two real provisioning runs.
    class RacingClient < FakeClient
      def initialize(sibling_hook:, **kwargs)
        super(**kwargs)
        @sibling_hook = sibling_hook
      end

      def create_repository_webhook(repo, **kwargs)
        created = super
        # The sibling's hook is now live on GitHub and registered in the shared
        # database — neither of which this run's cached listing shows.
        @hooks = @hooks + [ @sibling_hook ]
        CollavreGithub::RepositoryLink
          .where(repository_full_name: repo)
          .update_all(webhook_hook_id: @sibling_hook.id)
        created
      end
    end

    # GitHub serves the opening listing but fails the one that verifies whether
    # the registered hook still exists. The production Client swallows that
    # error and answers `[]`, which reads exactly like GitHub confirming the
    # hook is gone.
    class UnverifiableClient < FakeClient
      def repository_hooks!(_repo)
        raise Octokit::Error
      end
    end

    # GitHub refuses the cleanup DELETE while accepting everything else, so the
    # only thing that failed is removing a hook the repository no longer needs.
    class UndeletableClient < FakeClient
      def delete_repository_webhook(_repo, _hook_id)
        raise Octokit::Error
      end
    end

    OWN_URL = "https://collavre.com/github/webhooks".freeze
    SIBLING_URL = "https://local.collavre.com/github/webhooks".freeze
    LEGACY_URL = "https://collavre.com/github/webhook".freeze

    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @account = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "9001",
        login: "prov",
        name: "Prov",
        token: "t"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: "owner/repo"
      )
    end

    # `repository_id` is the only routing key that survives a repository
    # rename. Stamping it at provisioning time protects a link from its first
    # moment rather than from its first inbound delivery.
    test "stamps the repository id onto a link that has none" do
      client = FakeClient.new(repo_id: 4242)
      provision(client)

      assert_equal 4242, @link.reload.repository_id
    end

    test "does not overwrite a repository id that is already set" do
      # An existing id anchors the link to a specific repository. Letting a
      # provisioning run move it would undo exactly the protection it provides.
      @link.update!(repository_id: 1)
      provision(FakeClient.new(repo_id: 4242))

      assert_equal 1, @link.reload.repository_id
    end

    test "a failed repository id fetch does not fail provisioning" do
      # Name matching still works without an id, so this must never be the
      # thing that stops a hook being created.
      client = FakeClient.new(repo_id: nil)

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_nil @link.reload.repository_id
    end

    test "creates a hook when the repo has none" do
      client = FakeClient.new
      assert_equal [ [ @link, :created ] ], provision(client)
      assert_equal 1, client.created.size
      assert_equal OWN_URL, client.created.first[:url]
    end

    test "updates its own hook when the URL matches exactly" do
      client = FakeClient.new(hooks: [ Hook.new(1, { "url" => OWN_URL }) ])
      assert_equal [ [ @link, :updated ] ], provision(client)
      assert_empty client.created
      assert_equal 1, client.updated.first[:hook_id]
    end

    # The regression this PR fixes. Before the change, a hook under a different
    # host was invisible to this instance, so it created its own — leaving the
    # repo with two hooks and GitHub delivering every event twice.
    test "does not create a second hook when a sibling instance already owns one" do
      @link.update!(webhook_hook_id: 2)
      client = FakeClient.new(hooks: [ Hook.new(2, { "url" => SIBLING_URL }) ])

      assert_equal [ [ @link, :shared ] ], provision(client)
      assert_empty client.created, "must not add a second hook for the same database"
    end

    test "does not rewrite a sibling hook's URL to its own" do
      # Rewriting would break the sibling instance and start a rewrite war: each
      # side would keep patching the URL back to itself on every provision.
      @link.update!(webhook_hook_id: 2)
      client = FakeClient.new(hooks: [ Hook.new(2, { "url" => SIBLING_URL }) ])
      provision(client)

      assert_equal [ SIBLING_URL ], client.updated.map { |u| u[:url] }
      assert_empty client.deleted
    end

    test "refreshes the event list on a sibling's hook" do
      # `events_for` widens to include `push` as soon as any link enables
      # markdown sync, and the sibling that owns the hook has no reason to
      # reprovision. Skipping the patch let the initial sync run and then
      # silently miss every later push.
      @link.update!(webhook_hook_id: 2, markdown_sync_enabled: true)
      client = FakeClient.new(hooks: [ Hook.new(2, { "url" => SIBLING_URL }) ])

      assert_equal [ [ @link, :shared ] ], provision(client)
      assert_includes client.updated.first[:events], "push"
      assert_equal SIBLING_URL, client.updated.first[:url], "the sibling's URL must survive"
      assert_empty client.created
    end

    # Reuse leaves this instance with no hook of its own, so the repository's
    # deliveries all go to a host this deployment does not control. Nothing else
    # reports it: the hook exists and the links are linked, so a host that goes
    # away simply makes the repository go quiet.
    test "warns when the reused hook is on another host" do
      @link.update!(webhook_hook_id: 2)
      client = FakeClient.new(hooks: [
        Hook.new(2, { "url" => SIBLING_URL }, { "status" => "misdirected_request", "code" => 502 })
      ])

      log = capture_rails_log(Logger::WARN) { provision(client) }

      assert_includes log, SIBLING_URL
      assert_includes log, "misdirected_request 502",
        "GitHub's own record of the last delivery is what tells the two cases apart"
    end

    # Same host means the deliveries arrive here, so reuse costs nothing and
    # must not spend a warning — one that fires on the healthy path trains
    # operators to skip the field entirely.
    test "does not warn when the reused hook is on this instance's own host" do
      @link.update!(webhook_hook_id: 2)
      same_host = "#{OWN_URL}/"
      client = FakeClient.new(hooks: [ Hook.new(2, { "url" => same_host }) ])

      log = capture_rails_log(Logger::WARN) { provision(client) }

      assert_equal [ [ @link, :shared ] ], provision(client)
      assert_not_includes log, same_host
    end

    # A separate deployment can serve the very same path. It has its own
    # database and its own webhook secret, so its deliveries never reach this
    # instance — treating its hook as reusable would leave this instance
    # connected on paper and receiving nothing.
    test "does not defer to a same-path hook this database never registered" do
      client = FakeClient.new(hooks: [ Hook.new(2, { "url" => SIBLING_URL }) ])

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_equal 1, client.created.size
      assert_equal OWN_URL, client.created.first[:url]
    end

    test "records the created hook so a sibling instance can reuse it" do
      client = FakeClient.new(hooks: [], next_id: 40)
      provision(client)

      assert_equal 41, @link.reload.webhook_hook_id
    end

    test "records its own hook when it was created before registration existed" do
      client = FakeClient.new(hooks: [ Hook.new(7, { "url" => OWN_URL }) ])
      provision(client)

      assert_equal 7, @link.reload.webhook_hook_id
    end

    test "does not steal a registration while its hook is still live" do
      # Otherwise two instances take turns claiming the slot, each sees the
      # other's hook as unregistered on its next run, and the proliferation the
      # registry exists to stop comes straight back.
      @link.update!(webhook_hook_id: 2)
      client = FakeClient.new(hooks: [
        Hook.new(2, { "url" => SIBLING_URL }),
        Hook.new(3, { "url" => OWN_URL })
      ])

      provision(client)
      assert_equal 2, @link.reload.webhook_hook_id
    end

    test "replaces a registration whose hook no longer exists on GitHub" do
      @link.update!(webhook_hook_id: 999)
      client = FakeClient.new(hooks: [ Hook.new(3, { "url" => OWN_URL }) ])

      provision(client)
      assert_equal 3, @link.reload.webhook_hook_id
    end

    test "registers the hook on every link for the repository" do
      # Registration must survive the deletion of any single link, or the next
      # provisioning run would see an unregistered hook and create a duplicate.
      other = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: @link.repository_full_name
      )
      provision(FakeClient.new(hooks: [ Hook.new(8, { "url" => OWN_URL }) ]))

      assert_equal 8, other.reload.webhook_hook_id
    end

    test "fills in the registration on a link added after the hook was registered" do
      # The registration is already correct, so the compare-and-set has nothing
      # to write and returns early — which used to leave the newcomer null. The
      # older link is then the only carrier: delete it and the live hook becomes
      # unrecognisable, so a sibling host creates a second one.
      @link.update!(webhook_hook_id: 8)
      newcomer = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: @link.repository_full_name
      )

      provision(FakeClient.new(hooks: [ Hook.new(8, { "url" => OWN_URL }) ]))

      assert_equal 8, newcomer.reload.webhook_hook_id
    end

    test "filling in a registration does not overwrite a link naming another hook" do
      # Only null registrations are the backfill's to write. A link pointing at
      # a different hook is the stale-vs-live question the CAS answers, and
      # silently rewriting it here would decide that question the wrong way.
      @link.update!(webhook_hook_id: 8)
      dissenting = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: @link.repository_full_name,
        webhook_hook_id: 99
      )

      provision(FakeClient.new(hooks: [ Hook.new(8, { "url" => OWN_URL }) ]))

      assert_equal 99, dissenting.reload.webhook_hook_id
    end

    test "prefers its own hook over a sibling when both exist" do
      client = FakeClient.new(hooks: [
        Hook.new(2, { "url" => SIBLING_URL }),
        Hook.new(3, { "url" => OWN_URL })
      ])

      assert_equal [ [ @link, :updated ] ], provision(client)
      assert_equal 3, client.updated.first[:hook_id]
    end

    test "an unrelated hook on the same host is neither reused nor deleted" do
      client = FakeClient.new(hooks: [ Hook.new(5, { "url" => "https://ci.example.com/build" }) ])

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_empty client.deleted
    end

    test "deletes the legacy singular-path hook during provisioning" do
      # The singular route is still served, so this hook still delivers — which
      # is the problem: alongside the plural hook it doubles every delivery.
      # Removing it is what will eventually let the alias route go.
      client = FakeClient.new(hooks: [
        Hook.new(6, { "url" => LEGACY_URL }),
        Hook.new(7, { "url" => OWN_URL })
      ])

      provision(client)
      assert_equal [ { repo: "owner/repo", hook_id: 6 } ], client.deleted
    end

    test "failing to delete the legacy hook does not fail an otherwise good provision" do
      # The cleanup runs after the replacement is already in place, so losing it
      # costs one duplicate delivery — which the GUID ledger collapses. Letting
      # the error escape reaches ensure_webhook's rescue and reports :failed,
      # which pr_monitor surfaces as "GitHub API rejected the hook request":
      # an alarm about the very hook that had just been provisioned correctly.
      #
      # The production client swallows Octokit errors and returns nil, so this
      # raising client is the only thing that exercises the path — which is the
      # point: without it, the day a raising client is injected the failure mode
      # arrives silently.
      client = UndeletableClient.new(hooks: [ Hook.new(6, { "url" => LEGACY_URL }) ])

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_equal [ OWN_URL ], client.created.map { |c| c[:url] }
    end

    test "a trailing slash does not hide a legacy hook" do
      # Insignificant to Rails routing, so it must be insignificant here too —
      # otherwise the repo keeps a duplicate hook forever.
      client = FakeClient.new(hooks: [ Hook.new(12, { "url" => "#{LEGACY_URL}/" }) ])

      provision(client)
      assert_equal [ 12 ], client.deleted.map { |d| d[:hook_id] }
      # This fixture has no plural hook, so asserting the deletion alone would
      # pass just as happily with the repository left holding none at all —
      # the same vacuity that hid the bug two tests below.
      assert_equal [ OWN_URL ], client.created.map { |c| c[:url] },
        "the deleted hook must have been replaced first"
    end

    test "leaves an unregistered legacy hook under another host in place" do
      # The singular route is still served, so that hook may well be an
      # independent deployment's only way of receiving events. Deleting it on
      # nothing but a path match would take that deployment offline — deletion
      # has to rest on stronger evidence than reuse does, not weaker.
      client = FakeClient.new(hooks: [ Hook.new(8, { "url" => "https://other.example.com/github/webhook" }) ])

      provision(client)
      assert_empty client.deleted
      assert_equal 1, client.created.size, "legacy hook must not count as a reusable sibling"
    end

    test "deletes a legacy hook under another host once it is registered here" do
      # Registration is written only by an instance sharing this database, so
      # it is positive evidence the hook is ours to migrate.
      @link.update!(webhook_hook_id: 8)
      client = FakeClient.new(hooks: [ Hook.new(8, { "url" => "https://local.collavre.com/github/webhook" }) ])

      provision(client)
      assert_equal [ 8 ], client.deleted.map { |d| d[:hook_id] }
      # Asserting the deletion alone is what let the bug below hide: the repo
      # was left with no hook at all and this test still passed.
      assert_equal 1, client.created.size, "the deleted hook must have been replaced first"
    end

    test "replaces a registered legacy hook instead of reusing it" do
      # Registration made the legacy hook look like a reusable sibling, so
      # provisioning patched it, reported `:shared`, created nothing — and then
      # deleted it as a legacy hook, leaving the repository with no webhook at
      # all. Reuse and migration cannot both claim the same hook.
      @link.update!(webhook_hook_id: 8)
      client = FakeClient.new(hooks: [ Hook.new(8, { "url" => LEGACY_URL }) ])

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_equal [ OWN_URL ], client.created.map { |c| c[:url] }
      assert_equal [ 8 ], client.deleted.map { |d| d[:hook_id] }
    end

    test "the replacement takes over the registration from the legacy hook" do
      # The legacy hook is still live on GitHub while the replacement is being
      # registered, so the live-registration check would read it as a sibling
      # to defer to — discarding the registration of the hook just created and
      # then deleting the hook that registration named.
      @link.update!(webhook_hook_id: 8)
      client = FakeClient.new(hooks: [ Hook.new(8, { "url" => LEGACY_URL }) ])

      provision(client)

      registered = @link.reload.webhook_hook_id
      assert_predicate registered, :present?, "the replacement must be registered"
      refute_equal "8", registered.to_s,
        "the registration must name the replacement, not the hook that was deleted"
    end

    test "keeps the legacy hook when the replacement could not be created" do
      # Deleting first left the repo with no hook at all on a transient GitHub
      # error, and callers report success regardless, so events stopped until
      # provisioning happened to run again.
      client = FakeClient.new(hooks: [ Hook.new(6, { "url" => LEGACY_URL }) ])
      def client.create_repository_webhook(*, **)
        nil
      end

      assert_equal [ [ @link, :failed ] ], provision(client)
      assert_empty client.deleted, "the only working hook must survive a failed replacement"
    end

    test "removal deletes its own hook but leaves a sibling in place" do
      client = FakeClient.new(hooks: [
        Hook.new(9, { "url" => OWN_URL }),
        Hook.new(10, { "url" => SIBLING_URL })
      ])
      @link.destroy!

      CollavreGithub::WebhookProvisioner.new(
        account: @account, webhook_url: OWN_URL, client: client
      ).remove_for_repositories([ "owner/repo" ])

      assert_equal [ 9 ], client.deleted.map { |d| d[:hook_id] }
    end

    test "removal does not delete any hook while a link still exists" do
      client = FakeClient.new(hooks: [ Hook.new(11, { "url" => OWN_URL }) ])

      CollavreGithub::WebhookProvisioner.new(
        account: @account, webhook_url: OWN_URL, client: client
      ).remove_for_repositories([ "owner/repo" ])

      assert_empty client.deleted
    end

    test "removal keeps the hook when the surviving link is stored with different casing" do
      # The link that still needs the hook is spelled differently from the name
      # being unlinked. Comparing exactly would conclude nothing links the repo
      # any more and tear down a hook that is still in use.
      @link.update!(repository_full_name: "Owner/Repo")
      client = FakeClient.new(hooks: [ Hook.new(11, { "url" => OWN_URL }) ])

      CollavreGithub::WebhookProvisioner.new(
        account: @account, webhook_url: OWN_URL, client: client
      ).remove_for_repositories([ "owner/repo" ])

      assert_empty client.deleted
    end

    # Two instances provisioning the same repository at once both list no hooks,
    # both see no registration, and both create one. The registration writes
    # were plain last-writer-wins, so both hooks stayed live permanently and
    # every later run could only warn about them.
    test "deletes the hook it just created when a sibling wins the registration race" do
      sibling_hook = Hook.new(555, { "url" => SIBLING_URL })
      client = RacingClient.new(sibling_hook: sibling_hook)

      assert_equal [ [ @link, :shared ] ], provision(client)

      assert_equal 1, client.created.size, "the race is only interesting once both have created"
      assert_equal [ 101 ], client.deleted.map { |d| d[:hook_id] },
        "the instance that lost the race must remove the hook it created"
      assert_equal 555, @link.reload.webhook_hook_id,
        "the winner's registration must stand"
    end

    test "a registration whose hook is gone from GitHub is still replaced" do
      # The counterpart to the race above, and the reason it cannot simply defer
      # to any registration it finds: a registration left behind by a deleted
      # hook must not block this instance from creating a working one.
      @link.update!(webhook_hook_id: 999)
      client = FakeClient.new

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_equal 1, client.created.size
      assert_equal 101, @link.reload.webhook_hook_id
    end

    test "a registration GitHub could not vouch for is left alone" do
      # The sibling's hook is live but absent from the opening listing, so the
      # decision falls to the verification fetch — and that fetch fails. An
      # empty answer and no answer are the same value out of the swallowing
      # client, so this used to overwrite the registration with the hook just
      # created. The sibling's hook stays live and its id is then recorded
      # nowhere, which puts it beyond the reach of every later run.
      @link.update!(webhook_hook_id: 42)
      client = UnverifiableClient.new

      assert_equal [ [ @link, :created ] ], provision(client)
      assert_equal 42, @link.reload.webhook_hook_id,
        "an unanswered listing must not be read as confirmation the hook is gone"
    end

    test "a hook created while the registration could not be verified is kept" do
      # The counterpart to the assertion above, and the reason deferring is not
      # enough on its own: discarding the new hook would leave the repository
      # with nothing at all if the registration turns out to be stale, whereas
      # keeping it costs at most a duplicate delivery the ledger collapses.
      @link.update!(webhook_hook_id: 42)
      client = UnverifiableClient.new

      provision(client)
      assert_equal [ OWN_URL ], client.created.map { |c| c[:url] }
      assert_empty client.deleted, "the hook just created must not be undone on a guess"
    end

    test "recognises a registered hook through a link stored with different casing" do
      # GitHub serves one repository whatever the spelling, so both links
      # describe the same hooks. `repository_full_name` is stored verbatim from
      # whatever the caller supplied, so an exact match cannot see across them —
      # it would miss the registration and create a second hook, which is the
      # proliferation this class exists to prevent.
      CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: "Owner/Repo",
        webhook_hook_id: 2
      )
      client = FakeClient.new(hooks: [ Hook.new(2, { "url" => SIBLING_URL }) ])

      assert_equal [ [ @link, :shared ] ], provision(client)
      assert_empty client.created, "the differently-cased link's registration must be honoured"
    end

    test "subscribes to push when a differently-cased link enables markdown sync" do
      CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: "Owner/Repo",
        markdown_sync_enabled: true
      )
      client = FakeClient.new

      provision(client)

      assert_includes client.created.first[:events], "push"
    end

    private

    # Captured at WARN so the level itself is under test: an informational log
    # of the same text would leave these assertions unmet.
    def capture_rails_log(level)
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      Rails.logger.level = level
      yield
      io.string
    ensure
      Rails.logger = original
    end

    def provision(client, webhook_url: OWN_URL, links: nil)
      CollavreGithub::WebhookProvisioner.new(
        account: @account, webhook_url: webhook_url, client: client
      ).ensure_for_links(Array(links || @link))
    end
  end
end
