require "test_helper"

module Github
  class PullRequestAnalyzerTest < ActiveSupport::TestCase
    test "builds prompt with commit messages and diff" do
      payload = {
        "pull_request" => {
          "title" => "Improve feature",
          "body" => "Adds improvements"
        }
      }

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creatives(:tshirt),
        paths: [ "[1] Root > [2] Child" ],
        commit_messages: [ "Refactor module", "Add tests" ],
        diff: "diff --git a/file.rb b/file.rb\n+change"
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "1. Refactor module"
      assert_includes prompt, "2. Add tests"
      assert_includes prompt, "diff --git a/file.rb b/file.rb"
      assert_includes prompt, "Each node is shown as \"[ID] Title (progress XX%)\" when progress is known"
      assert_includes prompt, "Do not add tasks to \"completed\" if they already show 100% progress"
      assert_includes prompt, '"creative_id"'
      assert_includes prompt, '"parent_id"'
    end

    test "handles missing commit messages and diff" do
      payload = {
        "pull_request" => {
          "title" => "Improve feature",
          "body" => "Adds improvements"
        }
      }

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creatives(:tshirt),
        paths: [ "[1] Root > [2] Child" ],
        commit_messages: [],
        diff: nil
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "No commit messages available."
      assert_includes prompt, "(No diff available)"
    end

    test "parses structured response into tasks" do
      payload = { "pull_request" => { "title" => "Feature" } }
      creative = creatives(:tshirt)
      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: [ "[#{creative.id}] Root" ]
      )

      response = '{"completed":[{"creative_id":123,"progress":0.75,"note":"partial","path":"Root > Child"}],"additional":[{"parent_id":123,"description":"Add docs","progress":0.1}]}'
      parsed = analyzer.send(:parse_response, response)

      completed = parsed[:completed]
      assert_equal 1, completed.size
      assert_equal 123, completed.first.creative_id
      assert_in_delta 0.75, completed.first.progress
      assert_equal "partial", completed.first.note
      assert_equal "Root > Child", completed.first.path

      additional = parsed[:additional]
      assert_equal 1, additional.size
      assert_equal 123, additional.first.parent_id
      assert_equal "Add docs", additional.first.description
      assert_in_delta 0.1, additional.first.progress
    end
  end
end
