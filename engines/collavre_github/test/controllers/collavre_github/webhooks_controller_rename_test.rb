require_relative "../../test_helper"

module CollavreGithub
  # A repository rename changes `repository.full_name` in every subsequent
  # webhook payload while `repository.id` stays constant. Before these tests the
  # only lookup key was the name, so a rename detached every link at once: the
  # controller found no link, fell through to a fallback secret that production
  # does not set, and answered 401 *before* dispatch. Nothing was written to the
  # deliveries ledger, so the failure was invisible on this side.
  class WebhooksControllerRenameTest < ActionDispatch::IntegrationTest
    OLD_NAME = "owner/old-name".freeze
    NEW_NAME = "owner/new-name".freeze
    REPO_ID = 4242

    setup do
      # The announcement path carries a per-repo scan guard in Rails.cache, and
      # the test store is a memory store shared by every test in this process.
      # Without this, whichever test runs second sees the first one's guard.
      Rails.cache.clear
      @user = users(:one)
      @creative = creatives(:tshirt)
      @account = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "12345",
        login: "testuser",
        name: "Test",
        token: "test-token"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: REPO_ID
      )
      @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "T")
      @channel = GithubPrChannel.create!(
        topic: @topic,
        config: { "repo_full_name" => OLD_NAME, "pr_number" => 99 }
      )
    end

    def post_event(event, payload, secret: @link.webhook_secret, guid: SecureRandom.uuid, hook_id: nil)
      body = payload.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      headers = {
        "Content-Type" => "application/json",
        "X-GitHub-Event" => event,
        "X-GitHub-Delivery" => guid,
        "X-Hub-Signature-256" => sig
      }
      headers["X-GitHub-Hook-ID"] = hook_id.to_s if hook_id
      post "/github/webhooks",
        params: body,
        headers: headers
    end

    # --- repository_id matching -------------------------------------------

    test "signature verifies against a renamed repo when repository_id matches" do
      # The name in the payload matches nothing in the DB. Only the id does.
      post_event("issue_comment", {
        action: "created",
        comment: { id: 1, body: "hi", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: REPO_ID, full_name: NEW_NAME }
      })

      assert_response :ok
    end

    test "repository_id lookup does not displace sibling links matched by name" do
      # Fan-out regression guard: one link backfilled, one not. Both must
      # continue to receive. An id-first-else-name lookup would drop the
      # un-backfilled sibling the moment the first one was stamped.
      other_creative = creatives(:childless_creative)
      legacy = CollavreGithub::RepositoryLink.create!(
        creative: other_creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: nil
      )

      links = CollavreGithub::RepositoryLink.for_repository(id: REPO_ID, full_name: OLD_NAME)
      assert_includes links, @link
      assert_includes links, legacy
    end

    test "repository_id lookup excludes name matches anchored to another repository" do
      reused_name = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: 777
      )

      links = CollavreGithub::RepositoryLink.for_repository(id: REPO_ID, full_name: OLD_NAME)
      assert_includes links, @link
      assert_not_includes links, reused_name
    end

    test "signature lookup prefers an ID-backed link over an older NULL-id name match" do
      @link.destroy!
      stale = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: nil,
        webhook_secret: "stale-secret"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: REPO_ID
      )

      post_event("issue_comment", {
        action: "created",
        comment: { id: 100, body: "hi", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: REPO_ID, full_name: OLD_NAME }
      })

      assert_response :ok
      assert_nil stale.reload.repository_id
    end

    test "a reused repository name does not receive another repository's event" do
      other_creative = creatives(:childless_creative)
      CollavreGithub::RepositoryLink.create!(
        creative: other_creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: 777,
        webhook_secret: @link.webhook_secret
      )
      other_topic = Collavre::Topic.create!(creative: other_creative, user: @user, name: "Other")
      GithubPrChannel.create!(
        topic: other_topic,
        config: { "repo_full_name" => OLD_NAME, "pr_number" => 99 }
      )

      assert_no_difference -> { Collavre::Comment.where(topic_id: other_topic.id).count } do
        assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
          post_event("issue_comment", {
            action: "created",
            comment: { id: 101, body: "private", user: { login: "alice", type: "User", id: 1 } },
            issue: { number: 99, pull_request: {} },
            repository: { id: REPO_ID, full_name: OLD_NAME }
          })
        end
      end
      assert_response :ok
    end

    test "blank repository_id falls back to name matching" do
      links = CollavreGithub::RepositoryLink.for_repository(id: nil, full_name: OLD_NAME)
      assert_includes links, @link
    end

    test "repository_id is backfilled from a verified delivery" do
      @link.update_column(:repository_id, nil)

      post_event("issue_comment", {
        action: "created",
        comment: { id: 2, body: "hi", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: REPO_ID, full_name: OLD_NAME }
      })

      assert_response :ok
      assert_equal REPO_ID, @link.reload.repository_id
    end

    test "repository_id is not backfilled onto a stale name match with another secret" do
      other_creative = creatives(:childless_creative)
      other = CollavreGithub::RepositoryLink.create!(
        creative: other_creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: nil,
        webhook_secret: "other-repository-secret"
      )
      other_topic = Collavre::Topic.create!(creative: other_creative, user: @user, name: "Other")
      GithubPrChannel.create!(
        topic: other_topic,
        config: { "repo_full_name" => OLD_NAME, "pr_number" => 99 }
      )

      assert_no_difference -> { Collavre::Comment.where(topic_id: other_topic.id).count } do
        post_event("issue_comment", {
          action: "created",
          comment: { id: 21, body: "hi", user: { login: "alice", type: "User", id: 1 } },
          issue: { number: 99, pull_request: {} },
          repository: { id: REPO_ID, full_name: OLD_NAME }
        })
      end

      assert_response :ok
      assert_equal REPO_ID, @link.reload.repository_id
      assert_nil other.reload.repository_id
    end

    test "repository_id is NOT backfilled from an unverified delivery" do
      # The lookup runs before signature verification, so an unauthenticated
      # caller can reach it. Stamping an id there would let anyone repoint a
      # link's routing key at a repository they control.
      @link.update_column(:repository_id, nil)

      post_event("issue_comment", {
        action: "created",
        comment: { id: 3, body: "hi", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: 999_999, full_name: OLD_NAME }
      }, secret: "wrong-secret")

      assert_response :unauthorized
      assert_nil @link.reload.repository_id
    end

    test "a verified hook id repairs a missed rename and dispatches the current event" do
      @link.update_columns(repository_id: nil, webhook_hook_id: 77)

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post_event("issue_comment", {
          action: "created",
          comment: { id: 31, body: "after missed rename", user: { login: "alice", type: "User", id: 1 } },
          issue: { number: 99, pull_request: {} },
          repository: { id: REPO_ID, full_name: NEW_NAME }
        }, hook_id: 77)
      end

      assert_response :ok
      assert_equal REPO_ID, @link.reload.repository_id
      assert_equal NEW_NAME, @link.repository_full_name
      assert_equal NEW_NAME, @channel.reload.repo_full_name
    end

    test "an unverified hook id cannot repair repository identity" do
      @link.update_columns(repository_id: nil, webhook_hook_id: 77)

      post_event("issue_comment", {
        action: "created",
        comment: { id: 32, body: "forged", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: REPO_ID, full_name: NEW_NAME }
      }, secret: "wrong-secret", hook_id: 77)

      assert_response :unauthorized
      assert_nil @link.reload.repository_id
      assert_equal OLD_NAME, @link.repository_full_name
      assert_equal OLD_NAME, @channel.reload.repo_full_name
    end

    test "a malformed hook id is rejected without querying it as a bigint" do
      @link.update_columns(repository_id: nil, webhook_hook_id: 77)

      post_event("issue_comment", {
        action: "created",
        comment: { id: 33, body: "forged", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: REPO_ID, full_name: NEW_NAME }
      }, hook_id: "not-a-number")

      assert_response :unauthorized
      assert_nil @link.reload.repository_id
      assert_equal OLD_NAME, @link.repository_full_name
    end

    # --- repository.renamed ------------------------------------------------

    test "repository.renamed rewrites the link's full name" do
      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_response :ok
      assert_equal NEW_NAME, @link.reload.repository_full_name
    end

    test "repository.renamed rewrites attached channels' repo_full_name" do
      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_response :ok
      assert_equal NEW_NAME, @channel.reload.repo_full_name
    end

    test "renamed repo keeps dispatching to its channel afterwards" do
      # End-to-end: the rename must leave the (link, channel) pair consistent
      # enough that the very next PR comment still lands in the topic.
      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })
      assert_response :ok

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post_event("issue_comment", {
          action: "created",
          comment: { id: 4, body: "after rename", user: { login: "alice", type: "User", id: 1 } },
          issue: { number: 99, pull_request: {} },
          repository: { id: REPO_ID, full_name: NEW_NAME }
        })
      end
      assert_response :ok
    end

    test "repository.renamed leaves links for other repositories alone" do
      other = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: "owner/unrelated",
        repository_id: 777
      )

      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_equal "owner/unrelated", other.reload.repository_full_name
    end

    test "repository.renamed does not capture a different repository that reused the old name" do
      other_creative = creatives(:childless_creative)
      other = CollavreGithub::RepositoryLink.create!(
        creative: other_creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: 777
      )
      other_topic = Collavre::Topic.create!(creative: other_creative, user: @user, name: "Other")
      other_channel = GithubPrChannel.create!(
        topic: other_topic,
        config: { "repo_full_name" => OLD_NAME, "pr_number" => 100 }
      )

      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_response :ok
      assert_equal NEW_NAME, @link.reload.repository_full_name
      assert_equal OLD_NAME, other.reload.repository_full_name
      assert_equal OLD_NAME, other_channel.reload.repo_full_name
    end

    test "repository.renamed repairs an unbackfilled sibling with the verified secret" do
      other_creative = creatives(:childless_creative)
      sibling = CollavreGithub::RepositoryLink.create!(
        creative: other_creative,
        github_account: @account,
        repository_full_name: OLD_NAME,
        repository_id: nil,
        webhook_secret: @link.webhook_secret
      )
      sibling_topic = Collavre::Topic.create!(creative: other_creative, user: @user, name: "Sibling")
      sibling_channel = GithubPrChannel.create!(
        topic: sibling_topic,
        config: { "repo_full_name" => OLD_NAME, "pr_number" => 100 }
      )

      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_response :ok
      assert_equal NEW_NAME, sibling.reload.repository_full_name
      assert_equal REPO_ID, sibling.repository_id
      assert_equal NEW_NAME, sibling_channel.reload.repo_full_name
    end

    test "repository.renamed leaves a creative unchanged when the new name belongs to another id" do
      CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: NEW_NAME,
        repository_id: 777
      )

      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_response :ok
      assert_equal OLD_NAME, @link.reload.repository_full_name
      assert_equal OLD_NAME, @channel.reload.repo_full_name
    end

    test "repository.renamed merges an obsolete same-id link into the new-name survivor" do
      @link.update!(
        webhook_hook_id: 123,
        markdown_sync_enabled: true,
        markdown_root_creative: @creative,
        sync_branch: "docs"
      )
      survivor = CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: NEW_NAME,
        repository_id: REPO_ID,
        webhook_secret: "obsolete-secret"
      )

      post_event("repository", {
        action: "renamed",
        changes: { repository: { name: { from: "old-name" } } },
        repository: { id: REPO_ID, full_name: NEW_NAME, name: "new-name", owner: { login: "owner" } }
      })

      assert_response :ok
      assert_not CollavreGithub::RepositoryLink.exists?(@link.id)
      survivor.reload
      assert_equal @link.webhook_secret, survivor.webhook_secret
      assert_equal 123, survivor.webhook_hook_id
      assert survivor.markdown_sync_enabled?
      assert_equal @creative, survivor.markdown_root_creative
      assert_equal "docs", survivor.sync_branch
      assert_equal [ survivor.id ],
        CollavreGithub::RepositoryLink.where(creative: @creative, repository_id: REPO_ID).pluck(:id)
      assert_equal NEW_NAME, @channel.reload.repo_full_name
    end

    # --- 401 visibility ----------------------------------------------------
    #
    # These model the production incident exactly: the channel still carries the
    # repository name, but no RepositoryLink resolves to it any more, so no
    # secret can be found and every delivery is refused before dispatch.
    #
    # `orphan_the_link!` reproduces that state — a link whose stored name has
    # gone stale and which has no id to be found by either.

    def orphan_the_link!
      @link.update_columns(repository_full_name: "owner/somewhere-else", repository_id: nil)
    end

    def post_unidentifiable(id_seed, full_name: OLD_NAME, repository_id: REPO_ID)
      post_event("issue_comment", {
        action: "created",
        comment: { id: id_seed, body: "hi", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: repository_id, full_name: full_name }
      }, secret: "any-secret-at-all")
    end

    test "delivery for an unidentifiable repo announces itself in the monitoring channel" do
      # This is the whole point: a rejected delivery used to be visible only as
      # a red row in GitHub's hook UI. The people watching the topic saw
      # nothing at all — just silence where PR comments should have been.
      orphan_the_link!

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post_unidentifiable(5)
      end
      assert_response :unauthorized

      assert_match(/#{Regexp.escape(OLD_NAME)}/, Collavre::Comment.where(topic_id: @topic.id).last.content)
    end

    test "a mere signature mismatch announces nothing" do
      # The repository IS identifiable and a secret WAS found — the caller just
      # did not sign with it. Announcing here would let anyone who can guess a
      # monitored repository's name post into that topic at will.
      assert_no_difference -> { Collavre::Comment.count } do
        post_unidentifiable(6)
      end
      assert_response :unauthorized
    end

    test "repeated unidentifiable deliveries announce at most once per window" do
      orphan_the_link!

      3.times { |i| post_unidentifiable(10 + i) ; assert_response :unauthorized }

      assert_equal 1, Collavre::Comment.where(topic_id: @topic.id).count
    end

    test "unknown repository scans are globally throttled across names" do
      orphan_the_link!
      other_topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Other repo")
      GithubPrChannel.create!(
        topic: other_topic,
        config: { "repo_full_name" => "owner/other", "pr_number" => 100 }
      )

      post_unidentifiable(15)
      post_unidentifiable(16, full_name: "owner/other", repository_id: 777)

      assert_equal 1, Collavre::Comment.where(topic_id: @topic.id).count
      assert_equal 0, Collavre::Comment.where(topic_id: other_topic.id).count

      travel 2.minutes do
        post_unidentifiable(17, full_name: "owner/other", repository_id: 777)
      end
      assert_equal 1, Collavre::Comment.where(topic_id: other_topic.id).count
    end

    test "announcement is throttled per channel, not globally" do
      orphan_the_link!
      other_topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "T2")
      GithubPrChannel.create!(
        topic: other_topic,
        config: { "repo_full_name" => OLD_NAME, "pr_number" => 100 }
      )

      post_unidentifiable(20)

      assert_equal 1, Collavre::Comment.where(topic_id: @topic.id).count
      assert_equal 1, Collavre::Comment.where(topic_id: other_topic.id).count
    end

    test "delivery for an unmonitored repo announces nothing" do
      assert_no_difference -> { Collavre::Comment.count } do
        post_event("issue_comment", {
          action: "created",
          comment: { id: 30, body: "hi", user: { login: "alice", type: "User", id: 1 } },
          issue: { number: 99, pull_request: {} },
          repository: { id: 1, full_name: "someone/else" }
        }, secret: "wrong-secret")
      end
      assert_response :unauthorized
    end

    test "successful delivery clears the announcement throttle" do
      # Otherwise a repo that breaks, is repaired, then breaks again months
      # later stays silent the second time.
      orphan_the_link!
      post_unidentifiable(40)
      assert @channel.reload.config["auth_failure_notified_at"].present?

      # Repair: the link is pointed back at the repository it belongs to.
      @link.update_columns(repository_full_name: OLD_NAME, repository_id: REPO_ID)

      post_event("issue_comment", {
        action: "created",
        comment: { id: 41, body: "ok now", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: 99, pull_request: {} },
        repository: { id: REPO_ID, full_name: OLD_NAME }
      })
      assert_response :ok
      assert_nil @channel.reload.config["auth_failure_notified_at"]
    end
  end
end
