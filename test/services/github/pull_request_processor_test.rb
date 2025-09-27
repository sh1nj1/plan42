require "test_helper"
require "json"

module Github
  class PullRequestProcessorTest < ActiveSupport::TestCase
    test "creates comment with analyzer results" do
      user = users(:one)
      creative = Creative.create!(user: user, description: "Root")
      Creative.create!(user: user, parent: creative, description: "Child")
      account = GithubAccount.create!(user: user, github_uid: "1", login: "tester", token: "token")
      GithubRepositoryLink.create!(creative: creative, github_account: account, repository_full_name: "org/repo")

      payload = {
        "action" => "closed",
        "pull_request" => {
          "title" => "Add feature",
          "number" => 12,
          "html_url" => "https://github.com/org/repo/pull/12",
          "body" => "Implements feature",
          "merged" => true
        },
        "repository" => { "full_name" => "org/repo" }
      }

      completed_task = Github::PullRequestAnalyzer::CompletedTask.new(
        creative_id: creative.children.first.id,
        progress: 1.0,
        path: "Root > Child"
      )
      suggestion = Github::PullRequestAnalyzer::SuggestedTask.new(
        parent_id: creative.id,
        description: "Follow up",
        progress: nil
      )
      result = Github::PullRequestAnalyzer::Result.new(
        completed: [ completed_task ],
        additional: [ suggestion ],
        raw_response: "{\"completed\":[{\"creative_id\":#{completed_task.creative_id}}],\"additional\":[{\"parent_id\":#{suggestion.parent_id},\"description\":\"Follow up\"}]}"
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
      assert_equal Creatives::PathExporter.new(creative).full_paths_with_ids_and_progress, analyzer_args[:paths]

      comment = creative.comments.last
      assert comment.present?
      assert_includes comment.content, "#12"
      assert_includes comment.content, "[#{completed_task.creative_id}]"
      assert_includes comment.content, "Follow up"
      assert_includes comment.content, "Gemini 응답"
      assert comment.action.present?
      assert_equal account.user, comment.approver

      action_payload = JSON.parse(comment.action)
      assert_equal 2, action_payload["actions"].size
      update_action = action_payload["actions"].first
      create_action = action_payload["actions"].last
      assert_equal "update_creative", update_action["action"]
      assert_equal completed_task.creative_id, update_action["creative_id"]
      assert_equal "create_creative", create_action["action"]
      assert_equal suggestion.parent_id, create_action["parent_id"]
    end

    test "ignores unmerged pull requests" do
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
          "merged" => false
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
