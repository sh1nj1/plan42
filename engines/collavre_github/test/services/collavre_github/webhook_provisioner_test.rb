require_relative "../../test_helper"

module CollavreGithub
  class WebhookProvisionerTest < ActiveSupport::TestCase
    Hook = Struct.new(:id, :config)

    # Records every call so tests can assert on what did NOT happen — the whole
    # point of the fix is that a second hook is never created.
    class FakeClient
      attr_reader :created, :updated, :deleted
      attr_accessor :hooks

      def initialize(hooks: [], next_id: 100)
        @hooks = hooks
        @created = []
        @updated = []
        @deleted = []
        @next_id = next_id
      end

      def repository_hooks(_repo)
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
      # The singular route was removed, so this hook can only 404 — and until
      # GitHub disables it, it doubles pull_request deliveries.
      client = FakeClient.new(hooks: [
        Hook.new(6, { "url" => LEGACY_URL }),
        Hook.new(7, { "url" => OWN_URL })
      ])

      provision(client)
      assert_equal [ { repo: "owner/repo", hook_id: 6 } ], client.deleted
    end

    test "a trailing slash does not hide a legacy hook" do
      # Insignificant to Rails routing, so it must be insignificant here too —
      # otherwise the repo keeps a duplicate hook forever.
      client = FakeClient.new(hooks: [ Hook.new(12, { "url" => "#{LEGACY_URL}/" }) ])

      provision(client)
      assert_equal [ 12 ], client.deleted.map { |d| d[:hook_id] }
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

    private

    def provision(client, webhook_url: OWN_URL, links: nil)
      CollavreGithub::WebhookProvisioner.new(
        account: @account, webhook_url: webhook_url, client: client
      ).ensure_for_links(Array(links || @link))
    end
  end
end
