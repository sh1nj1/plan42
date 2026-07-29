require_relative "../../test_helper"

module CollavreGithub
  # One repository reachable from TWO creatives. Every existing fan-out test
  # puts the sibling topics under a SINGLE creative with a SINGLE
  # RepositoryLink, so the variants below are uncovered.
  class WebhooksControllerMultiCreativeTest < ActionDispatch::IntegrationTest
    REPO = "owner/repo".freeze
    PR = 99

    setup do
      @user = users(:one)
      @account = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "12345",
        login: "testuser",
        name: "Test",
        token: "test-token"
      )
    end

    # Variant 1: two independent creatives, each carrying its own link.
    test "V1 two independent creatives each with their own link both receive" do
      a = creatives(:tshirt)
      b = creatives(:root_parent)
      link!(a)
      link!(b)
      ta, tb = topic_with_channel(a), topic_with_channel(b)

      deliver_issue_comment

      assert_equal 1, comments(ta), "creative A channel"
      assert_equal 1, comments(tb), "creative B channel"
    end

    # Variant 2: link lives only on a shared ancestor; topics hang off two
    # different descendant creatives.
    test "V2 link on a common ancestor reaches topics in both descendants" do
      root = creatives(:root_parent)
      link!(root)
      ta = topic_with_channel(creatives(:unconvert_target))
      tb = topic_with_channel(creatives(:childless_creative))

      deliver_issue_comment

      assert_equal 1, comments(ta), "descendant A channel"
      assert_equal 1, comments(tb), "descendant B channel"
    end

    # Variant 3: the second creative is a LINKED creative (origin_id set) whose
    # origin carries the repository link. Linking always writes to
    # `effective_origin`, so this is the row the UI produces.
    #
    # KNOWN GAP, characterized rather than asserted-as-desired. The scope gate
    # compares raw creative ids and never resolves `effective_origin`, so an
    # alias is out of scope even though the link on its origin is what the UI
    # wrote. Latent in practice — topics resolve to `effective_origin` on
    # creation (topics_controller.rb) — so no live path reaches it today.
    #
    # Widening the gate is a security decision, not a cleanup: the same check
    # is what stops a PR description from injecting into another tenant's
    # topic. Left for that decision; if the gate changes, this test fails and
    # tells you to make the change deliberately.
    test "V3 alias creative is out of scope even when its origin holds the link" do
      origin = creatives(:tshirt)
      link!(origin)
      ta = topic_with_channel(origin)

      alias_creative = Collavre::Creative.create!(
        user: @user, origin: origin, description: "Alias of tshirt"
      )
      tb = topic_with_channel(alias_creative)

      deliver_issue_comment

      assert_equal 1, comments(ta), "origin creative channel"
      assert_equal 0, comments(tb), "alias creative channel — known gap, see comment"
    end

    # Variant 4: pr_monitor attaches a channel on a creative with no link in
    # scope. Does the tool report the attach as successful anyway?
    test "V4 pr_monitor on an unlinked creative reports ok but never delivers" do
      linked = creatives(:tshirt)
      link!(linked)
      unlinked = creatives(:root_parent)
      topic = Collavre::Topic.create!(creative: unlinked, user: @user, name: "Unlinked")

      Collavre::Current.user = @user
      result = CollavreGithub::Tools::PrMonitorService.new.call(
        topic_id: topic.id, pr_url: "https://github.com/#{REPO}/pull/#{PR}"
      )
      assert result[:ok], "pr_monitor reported failure; expected the silent-success path"
      assert result[:webhook_warning].present?,
        "the only trace of the silent failure is this warning field, which callers ignore"

      before = comments(topic)
      deliver_issue_comment
      assert_equal before, comments(topic),
        "channel attached on an unlinked creative received the event"
    end

    # Variant 5: the repo is linked on a creative that is a DESCENDANT of the
    # topic's creative (linking happens wherever the user opened the settings
    # modal; the scope check only walks upward).
    #
    # KNOWN GAP, characterized rather than asserted-as-desired — same decision
    # as V3. A link is only ever valid DOWN its own subtree, so a topic sitting
    # above the linked creative is silently unreachable: the chip attaches, the
    # "monitoring started" message posts, and no event ever arrives. Widening
    # the gate downward would mean "a link anywhere below me lets a PR body
    # inject above me", which is the guard's whole purpose.
    test "V5 link on a descendant of the topic creative never reaches the topic" do
      parent = creatives(:root_parent)
      link!(creatives(:unconvert_target)) # a child of root_parent
      topic = topic_with_channel(parent)

      deliver_issue_comment

      assert_equal 0, comments(topic),
        "topic whose creative sits ABOVE the linked creative — known gap, see comment"
    end

    private

    def link!(creative)
      CollavreGithub::RepositoryLink.create!(
        creative: creative, github_account: @account, repository_full_name: REPO
      )
    end

    def topic_with_channel(creative)
      topic = Collavre::Topic.create!(creative: creative, user: @user, name: "T#{creative.id}")
      GithubPrChannel.create!(
        topic: topic, config: { "repo_full_name" => REPO, "pr_number" => PR }
      )
      topic
    end

    def comments(topic)
      Collavre::Comment.where(topic_id: topic.id).count
    end

    def deliver_issue_comment
      payload = {
        action: "created",
        comment: { id: 1, body: "review ping", user: { login: "alice", type: "User", id: 1 } },
        issue: { number: PR, pull_request: {} },
        repository: { full_name: REPO }
      }.to_json

      secret = CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", REPO).first.webhook_secret
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, payload)

      post "/github/webhooks",
        params: payload,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "issue_comment",
          "X-GitHub-Delivery" => SecureRandom.uuid,
          "X-Hub-Signature-256" => sig
        }
      assert_response :ok
    end
  end
end
