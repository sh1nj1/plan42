require "test_helper"

module Github
  class PullRequestProcessorTest < ActiveSupport::TestCase
    test "creates comment with analyzer results" do
      user = users(:one)
      creative = Creative.create!(user: user, description: "Root")
      Creative.create!(user: user, parent: creative, description: "Child")
      account = GithubAccount.create!(user: user, github_uid: "1", login: "tester", token: "token")
      GithubRepositoryLink.create!(creative: creative, github_account: account, repository_full_name: "org/repo")

      payload = {
        "action" => "opened",
        "pull_request" => {
          "title" => "Add feature",
          "number" => 12,
          "html_url" => "https://github.com/org/repo/pull/12",
          "body" => "Implements feature"
        },
        "repository" => { "full_name" => "org/repo" }
      }

      result = Github::PullRequestAnalyzer::Result.new(
        completed: [ "Root > Child" ],
        additional: [ "Root > Child > Follow up" ],
        raw_response: '{"completed":["Root > Child"],"additional":["Root > Child > Follow up"]}'
      )

      fake_analyzer = Minitest::Mock.new
      fake_analyzer.expect(:call, result)
      fake_client = Minitest::Mock.new
      fake_client.expect(:pull_request_commit_messages, [ "Initial commit" ], [ "org/repo", 12 ])
      fake_client.expect(:pull_request_diff, "diff --git a/file.rb b/file.rb\n+change", [ "org/repo", 12 ])

      analyzer_args = nil

      Github::Client.stub(:new, ->(_) { fake_client }) do
        Github::PullRequestAnalyzer.stub(:new, ->(**kwargs) { analyzer_args = kwargs; fake_analyzer }) do
          Github::PullRequestProcessor.new(payload: payload).call
        end
      end

      fake_analyzer.verify
      fake_client.verify

      assert_equal [ "Initial commit" ], analyzer_args[:commit_messages]
      assert_equal "diff --git a/file.rb b/file.rb\n+change", analyzer_args[:diff]

      comment = creative.comments.last
      assert comment.present?
      assert_includes comment.content, "#12"
      assert_includes comment.content, "Root > Child"
      assert_includes comment.content, "Root > Child > Follow up"
      assert_includes comment.content, "Gemini 응답"
    end

    test "ignores merged pull requests" do
      user = users(:one)
      creative = Creative.create!(user: user, description: "Root")
      account = GithubAccount.create!(user: user, github_uid: "1", login: "tester", token: "token")
      GithubRepositoryLink.create!(creative: creative, github_account: account, repository_full_name: "org/repo")

      payload = {
        "action" => "closed",
        "pull_request" => {
          "title" => "Add feature",
          "number" => 13,
          "html_url" => "https://github.com/org/repo/pull/13",
          "body" => "Implements feature",
          "merged" => true
        },
        "repository" => { "full_name" => "org/repo" }
      }

      Github::PullRequestAnalyzer.stub(:new, ->(*) { raise "should not be called" }) do
        assert_no_changes -> { creative.comments.count } do
          Github::PullRequestProcessor.new(payload: payload).call
        end
      end
    end
  end
end
