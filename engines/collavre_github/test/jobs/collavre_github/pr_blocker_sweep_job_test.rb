require_relative "../../test_helper"

module CollavreGithub
  class PrBlockerSweepJobTest < ActiveSupport::TestCase
    setup do
      user = users(:one)
      @parent = Collavre::Creative.create!(description: "Repository", user: user)
      @creative = Collavre::Creative.create!(description: "Task", parent: @parent, user: user)
      @topic = Collavre::Topic.create!(name: "PR", creative: @creative, user: user)
      @channel = GithubPrChannel.create!(topic: @topic, config: { "repo_full_name" => "owner/repo", "pr_number" => 42 })
      account = create_github_account(user)
      @link = RepositoryLink.create!(
        creative: @parent, github_account: account, repository_full_name: "Owner/Repo", repository_id: 123
      )
      @api = "https://api.github.com/repos/owner/repo"
      stub_pr(mergeable: false)
      stub_checks("sha1")
      stub_discussion
    end

    test "all scheduled sweeps share a concurrency key" do
      key = PrBlockerSweepJob.new.concurrency_key
      assert_includes key, "github-pr-blocker-sweep"
      assert_equal key, PrBlockerSweepJob.new.concurrency_key
    end

    test "posts conflicts and failed checks in the attached topic once" do
      stub_checks("sha1", runs: [
        { id: 1, name: "Rails", status: "completed", conclusion: "failure" },
        { id: 2, name: "Lint", status: "completed", conclusion: "success" },
        { id: 3, name: "Queued", status: "queued" }
      ], statuses: [
        { id: 4, context: "External CI", state: "error" },
        { id: 5, context: "Deploy", state: "pending" }
      ])

      dispatched = []
      dispatch = lambda do |event, payload, **|
        dispatched << [ event, payload ]
        []
      end
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, dispatch) do
        assert_difference -> { topic_comments.count }, 2 do
          PrBlockerSweepJob.perform_now
          PrBlockerSweepJob.perform_now
        end
      end

      conflict, checks = topic_comments.order(:id).to_a
      assert_includes conflict.content, "has a merge conflict"
      assert_includes checks.content, "Rails, External CI"
      assert_includes checks.content, "/pull/42/checks"
      assert_equal Collavre::Channel::BOT_EMAIL, checks.user.email
      assert_not checks.private?
      assert_equal @channel.pr_url, @channel.reload.latest_link
      assert_equal %w[comment_created comment_created], dispatched.map(&:first)
      assert_equal [ conflict.id, checks.id ], dispatched.map { |_, payload| payload.dig(:comment, :id) }
      assert_equal [ @topic.id, @topic.id ], dispatched.map { |_, payload| payload.dig(:topic, :id) }
    end

    test "reconciles all three discussion events and shares webhook deduplication" do
      stub_pr(mergeable: true)
      recent = (@channel.created_at + 1.second).iso8601
      author = { login: "reviewer" }
      issue_comment = { id: 10, created_at: recent, body: "General feedback", user: author }
      inline_comment = { id: 10, created_at: recent, body: "Inline feedback", user: author, path: "app.rb", line: 4 }
      review = { id: 10, submitted_at: recent, state: "CHANGES_REQUESTED", body: "Review feedback", user: author }
      stub_discussion(
        comments: [ issue_comment, issue_comment.merge(id: 11, created_at: (@channel.created_at - 1.second).iso8601) ],
        reviews: [ review, review.except(:submitted_at).merge(id: 11, state: "PENDING") ]
      )

      comments_url = "#{@api}/pulls/42/comments"
      next_page = "#{comments_url}?page=2"
      stub_request(:get, %r{#{comments_url}})
        .to_return(json([]).tap do |response|
          response[:headers]["Link"] = %(<#{next_page}>; rel="next")
          response[:headers]["X-RateLimit-Remaining"] = "100"
        end)
      stub_request(:get, next_page).to_return(json([ inline_comment ]))

      assert_difference -> { topic_comments.count }, 3 do
        deliver("issue_comment", action: "created", issue: { pull_request: {} }, comment: issue_comment)
        PrBlockerSweepJob.perform_now
        PrBlockerSweepJob.perform_now
        deliver("pull_request_review_comment", action: "created", comment: inline_comment)
        deliver("pull_request_review", action: "submitted", review: review)
      end

      contents = topic_comments.pluck(:content)
      assert_equal 1, contents.count { |content| content.include?("General feedback") }
      assert_equal 1, contents.count { |content| content.include?("Inline feedback") }
      assert_equal 1, contents.count { |content| content.include?("Review feedback") && content.include?("changes_requested") }
    end

    test "starts legacy channels after their last delivered message" do
      earlier = @channel.created_at + 1.second
      last_event = earlier + 1.second
      @channel.update!(config: @channel.config.except("discussion_poll_since"), last_event_at: last_event)
      author = { login: "alice" }
      stub_pr(mergeable: true)
      stub_discussion(comments: [
        { id: 1, created_at: earlier.iso8601, user: author, body: "Old feedback" },
        { id: 2, created_at: (last_event + 1.second).iso8601, user: author, body: "Missed feedback" }
      ])

      assert_difference -> { topic_comments.count }, 1 do
        PrBlockerSweepJob.perform_now
        PrBlockerSweepJob.perform_now
      end
      assert_includes topic_comments.last.content, "Missed feedback"
      assert_equal last_event.iso8601(6), @channel.reload.config["discussion_poll_since"]
    end

    test "continues with other events if one discussion endpoint fails" do
      stub_request(:get, %r{#{@api}/issues/42/comments}).to_return(status: 403)
      stub_request(:get, %r{#{@api}/pulls/42/comments}).to_return(json([
        { id: 15, created_at: (@channel.created_at + 1.second).iso8601, user: { login: "alice" }, body: "Inline feedback" }
      ]))

      assert_difference -> { topic_comments.count }, 2 do
        PrBlockerSweepJob.perform_now
      end
      assert topic_comments.any? { |comment| comment.content.include?("Inline feedback") }
    end

    test "waits for mergeability and reports a conflict again after recovery" do
      stub_pr(mergeable: nil)
      assert_no_difference -> { topic_comments.count } do
        PrBlockerSweepJob.perform_now
      end
      stub_pr(mergeable: false)
      assert_difference -> { topic_comments.count }, 1 do
        PrBlockerSweepJob.perform_now
        stub_pr(mergeable: nil)
        PrBlockerSweepJob.perform_now
        stub_pr(mergeable: false)
        PrBlockerSweepJob.perform_now
      end
      stub_pr(mergeable: true)
      PrBlockerSweepJob.perform_now
      stub_pr(mergeable: false)
      assert_difference -> { topic_comments.count }, 1 do
        PrBlockerSweepJob.perform_now
      end
    end

    test "reports failed reruns and resets check tracking on a new head" do
      assert_difference -> { topic_comments.count }, 3 do
        stub_pr(mergeable: true)
        stub_checks("sha1", runs: [ failed_run("2026-11-26T00:00:00Z") ])
        PrBlockerSweepJob.perform_now
        stub_checks("sha1", runs: [ failed_run("2026-11-26T00:05:00Z") ])
        PrBlockerSweepJob.perform_now
        stub_pr(mergeable: true, head: "sha2")
        stub_checks("sha2", runs: [ failed_run("2026-11-26T00:10:00Z") ])
        PrBlockerSweepJob.perform_now
      end
    end

    test "skips detached, unlinked, unverified, mismatched and closed PRs" do
      assert_no_difference -> { topic_comments.count } do
        @channel.detach!
        PrBlockerSweepJob.perform_now
        assert_not_requested :get, "#{@api}/pulls/42"
        @channel.update!(state: :active)
        @link.update!(repository_id: nil)
        PrBlockerSweepJob.perform_now
        assert_not_requested :get, "#{@api}/pulls/42"
        @link.update!(repository_id: 999)
        PrBlockerSweepJob.perform_now
        @link.update!(repository_id: 123)
        stub_pr(mergeable: false, state: "closed")
        PrBlockerSweepJob.perform_now
        assert_not_requested :get, check_runs_url("sha1")
        @link.destroy!
        PrBlockerSweepJob.perform_now
      end
    end

    test "a failed checks request does not suppress a conflict or another CI source" do
      stub_request(:get, check_runs_url("sha1")).to_return(status: 403)
      stub_request(:get, commit_status_url("sha1"))
        .to_return(json(statuses: [ { id: 7, state: "failure", context: "External CI" } ]))
      assert_difference -> { topic_comments.count }, 2 do
        PrBlockerSweepJob.perform_now
      end
    end

    test "includes failed statuses from later GitHub pages" do
      first_page = commit_status_url("sha1")
      next_page = "#{@api}/commits/sha1/status?page=2"
      stub_pr(mergeable: true)
      stub_request(:get, first_page).to_return(json(statuses: []).tap do |response|
        response[:headers]["Link"] = %(<#{next_page}>; rel="next")
        response[:headers]["X-RateLimit-Remaining"] = "100"
      end)
      stub_request(:get, next_page)
        .to_return(json(statuses: [ { id: 7, state: "failure", context: "External CI" } ]))

      assert_difference -> { topic_comments.count }, 1 do
        PrBlockerSweepJob.perform_now
      end
      assert_includes topic_comments.last.content, "External CI"
    end

    test "a failed commit status request does not suppress check run failures" do
      stub_pr(mergeable: true)
      stub_checks("sha1", runs: [ failed_run("2026-11-26T00:00:00Z") ])
      stub_request(:get, commit_status_url("sha1")).to_return(status: 403)

      assert_difference -> { topic_comments.count }, 1 do
        PrBlockerSweepJob.perform_now
      end
      assert_includes topic_comments.last.content, "Rails"
    end

    test "does not post when the channel is dismissed during the GitHub request" do
      stub_request(:get, commit_status_url("sha1")).to_return do
        @channel.dismiss!
        json(statuses: [])
      end

      assert_no_difference -> { topic_comments.count } do
        PrBlockerSweepJob.perform_now
      end
    end

    test "continues the sweep when a monitored channel cannot be checked" do
      GithubPrChannel.create!(
        topic: @topic, config: { "repo_full_name" => "owner/repo", "pr_number" => 12 }
      )
      stub_request(:get, "#{@api}/pulls/12").to_return(json(state: "open"))
      stub_request(:get, "#{@api}/pulls/42").to_return(json(state: "open", base: { repo: { id: 123 } }, head: { sha: nil }))

      assert_no_difference -> { topic_comments.count } do
        PrBlockerSweepJob.perform_now
      end
      assert_requested :get, "#{@api}/pulls/12"
      assert_requested :get, "#{@api}/pulls/42"
      assert_not_requested :get, check_runs_url("sha1")
    end

    private

    def topic_comments
      @creative.comments.where(topic_id: @topic.id)
    end

    def deliver(event, payload)
      @channel.with_lock do
        @channel.deliver_event!(event: event, payload: payload.deep_stringify_keys)
      end
    end

    def stub_discussion(comments: [], inline: [], reviews: [])
      stub_request(:get, %r{#{@api}/issues/42/comments}).to_return(json(comments))
      stub_request(:get, %r{#{@api}/pulls/42/comments}).to_return(json(inline))
      stub_request(:get, %r{#{@api}/pulls/42/reviews}).to_return(json(reviews))
    end

    def stub_pr(mergeable:, head: "sha1", state: "open")
      stub_request(:get, "#{@api}/pulls/42")
        .to_return(json(state: state, mergeable: mergeable, base: { repo: { id: 123 } }, head: { sha: head }))
    end

    def stub_checks(sha, runs: [], statuses: [])
      stub_request(:get, check_runs_url(sha)).to_return(json(check_runs: runs))
      stub_request(:get, commit_status_url(sha)).to_return(json(statuses: statuses))
    end

    def check_runs_url(sha)
      /#{Regexp.escape("#{@api}/commits/#{sha}/check-runs")}/
    end

    def commit_status_url(sha)
      /#{Regexp.escape("#{@api}/commits/#{sha}/status")}/
    end

    def json(data)
      { body: data.to_json, headers: { "Content-Type" => "application/json" } }
    end

    def failed_run(completed_at)
      { id: 9, name: "Rails", status: "completed", conclusion: "timed_out", completed_at: completed_at }
    end
  end
end
