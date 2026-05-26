require "test_helper"

module CollavreGithub
  class GithubPrChannelTest < ActiveSupport::TestCase
    setup do
      # NOTE: collavre_topics(:one) fixture does not exist; create inline.
      @user = Collavre::User.find_by!(email: "one@example1.com")
      @creative = Collavre::Creative.create!(description: "Test", user: @user)
      @topic = Collavre::Topic.create!(name: "T", creative: @creative, user: @user)
      @channel = GithubPrChannel.create!(
        topic: @topic,
        config: { "repo_full_name" => "owner/repo", "pr_number" => 42 }
      )
    end

    test "handle returns InjectedMessage for issue_comment.created" do
      payload = {
        "action" => "created",
        "comment" => {
          "id" => 1001,
          "body" => "please fix typo",
          "html_url" => "https://github.com/owner/repo/pull/42#issuecomment-1001",
          "user" => { "login" => "alice", "type" => "User", "id" => 7 }
        },
        "issue" => { "number" => 42, "pull_request" => {} },
        "repository" => { "full_name" => "owner/repo" }
      }

      result = @channel.handle(event: "issue_comment", payload: payload)
      assert_kind_of Collavre::Channel::InjectedMessage, result
      assert_includes result.message, "alice"
      assert_includes result.message, "please fix typo"
      assert_equal "PR #42", result.label
      assert_equal "https://github.com/owner/repo/pull/42", result.link
    end

    test "handle returns nil when action is not created" do
      payload = {
        "action" => "edited",
        "comment" => { "body" => "x", "user" => { "login" => "a", "type" => "User" } },
        "issue" => { "number" => 42, "pull_request" => {} },
        "repository" => { "full_name" => "owner/repo" }
      }
      assert_nil @channel.handle(event: "issue_comment", payload: payload)
    end

    test "handle returns nil when issue has no pull_request (plain issue)" do
      payload = {
        "action" => "created",
        "comment" => { "body" => "x", "user" => { "login" => "a", "type" => "User" } },
        "issue" => { "number" => 42 },
        "repository" => { "full_name" => "owner/repo" }
      }
      assert_nil @channel.handle(event: "issue_comment", payload: payload)
    end

    test "handle returns InjectedMessage for pull_request_review_comment.created" do
      payload = {
        "action" => "created",
        "comment" => {
          "id" => 2002,
          "body" => "rename this var",
          "path" => "app/foo.rb",
          "line" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42#discussion_r2002",
          "user" => { "login" => "bob", "type" => "User", "id" => 8 }
        },
        "pull_request" => { "number" => 42 },
        "repository" => { "full_name" => "owner/repo" }
      }
      result = @channel.handle(event: "pull_request_review_comment", payload: payload)
      assert_kind_of Collavre::Channel::InjectedMessage, result
      assert_includes result.message, "bob"
      assert_includes result.message, "app/foo.rb"
      assert_includes result.message, "rename this var"
    end

    test "handle returns InjectedMessage for pull_request_review.submitted with body" do
      payload = {
        "action" => "submitted",
        "review" => {
          "id" => 3003,
          "state" => "changes_requested",
          "body" => "Overall LGTM but please address comments.",
          "html_url" => "https://github.com/owner/repo/pull/42#pullrequestreview-3003",
          "user" => { "login" => "carol", "type" => "User", "id" => 9 }
        },
        "pull_request" => { "number" => 42 },
        "repository" => { "full_name" => "owner/repo" }
      }
      result = @channel.handle(event: "pull_request_review", payload: payload)
      assert_kind_of Collavre::Channel::InjectedMessage, result
      assert_includes result.message, "carol"
      assert_includes result.message, "changes_requested"
      assert_includes result.message, "Overall LGTM"
    end

    test "handle returns nil for pull_request_review.submitted with empty body" do
      payload = {
        "action" => "submitted",
        "review" => {
          "state" => "approved",
          "body" => "",
          "user" => { "login" => "carol", "type" => "User" }
        },
        "pull_request" => { "number" => 42 },
        "repository" => { "full_name" => "owner/repo" }
      }
      assert_nil @channel.handle(event: "pull_request_review", payload: payload)
    end
  end
end
