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

      Github::PullRequestAnalyzer.stub(:new, ->(*) { fake_analyzer }) do
        Github::PullRequestProcessor.new(payload: payload).call
      end

      fake_analyzer.verify

      comment = creative.comments.last
      assert comment.present?
      assert_includes comment.content, "#12"
      assert_includes comment.content, "Root > Child"
      assert_includes comment.content, "Root > Child > Follow up"
      assert_includes comment.content, "Gemini 응답"
    end
  end
end
