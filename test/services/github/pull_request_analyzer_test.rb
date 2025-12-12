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
        paths: [], # paths argument is now ignored for tree generation
        commit_messages: [ "Refactor module", "Add tests" ],
        diff: "diff --git a/file.rb b/file.rb\n+change"
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "1. Refactor module"
      assert_includes prompt, "2. Add tests"
      assert_includes prompt, "diff --git a/file.rb b/file.rb"

      # Verify new Prompt Description
      assert_includes prompt, "Creative tree structure"
      assert_includes prompt, "Format: - {id: <ID>, progress: <0.0-1.0>, desc: \"<Description>\"}"

      # Verify Tree Content (using regex or substring if ID is predictable)
      # Fixture id is 754382202, desc "T-Shirt"
      assert_includes prompt, "{id: #{creatives(:tshirt).id}, progress: 0.5, desc: \"T-Shirt\"}"

      assert_includes prompt, "Do not add tasks to \"completed\" if they already show 100% progress"
      assert_includes prompt, '"creative_id"'
      assert_includes prompt, '"parent_id"'
      assert_includes prompt, "new creatives that are not already represented"
      assert_includes prompt, "Do not use this list for follow-up tasks"
      assert_includes prompt, "When describing creatives, write from an end-user perspective"
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
        paths: [],
        commit_messages: [],
        diff: nil
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "No commit messages available."
      assert_includes prompt, "(No diff available)"
    end

    test "uses creative github gemini prompt template with placeholders" do
      creative = creatives(:tshirt)
      creative.update!(github_gemini_prompt: <<~PROMPT)
        Title: \#{pr_title}
        Body: \#{pr_body}
        Commits: \#{commit_messages}
        Diff: \#{diff}
        Tree: \#{creative_tree}
        Lang: \#{language_instructions}
      PROMPT

      payload = {
        "pull_request" => {
          "title" => "Improve feature",
          "body" => "Adds improvements"
        }
      }

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: [],
        commit_messages: [ "Refactor module" ],
        diff: "diff --git a/file.rb b/file.rb\n+change"
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "Title: Improve feature"
      assert_includes prompt, "Body: Adds improvements"
      assert_includes prompt, "Commits: 1. Refactor module"
      assert_includes prompt, "Diff: diff --git a/file.rb b/file.rb"
      assert_includes prompt, "Tree: - {id: #{creative.id}, progress: 0.5, desc: \"T-Shirt\"}"
      assert_includes prompt, "Lang: Preferred response language:"
    end


    test "uses english style guidance even when locale is ko" do
      payload = { "pull_request" => { "title" => "Feature" } }
      creative = creatives(:tshirt)
      creative.user.update!(locale: "ko")

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: [ { path: "[#{creative.id}] 루트", leaf: true } ]
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "Preferred response language:"
      assert_includes prompt, "When describing creatives, write from an end-user perspective"
    end

    test "parses structured response into tasks" do
      payload = { "pull_request" => { "title" => "Feature" } }
      creative = creatives(:tshirt)
      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: [ { path: "[#{creative.id}] Root", leaf: true } ]
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
