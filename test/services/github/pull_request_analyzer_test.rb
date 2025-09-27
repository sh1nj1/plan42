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
        paths: [ "Root > Child" ],
        commit_messages: [ "Refactor module", "Add tests" ],
        diff: "diff --git a/file.rb b/file.rb\n+change"
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "1. Refactor module"
      assert_includes prompt, "2. Add tests"
      assert_includes prompt, "diff --git a/file.rb b/file.rb"
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
        paths: [ "Root > Child" ],
        commit_messages: [],
        diff: nil
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "No commit messages available."
      assert_includes prompt, "(No diff available)"
    end

    test "appends default instructions after custom prompt" do
      creative = creatives(:tshirt)
      creative.update!(github_gemini_prompt: "Custom prompt instructions")

      payload = {
        "pull_request" => {
          "title" => "Improve feature",
          "body" => "Adds improvements"
        }
      }

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: [ "Root > Child" ],
        commit_messages: [],
        diff: nil
      )

      messages = analyzer.send(:build_messages)
      prompt = messages.dig(0, :parts, 0, :text)

      assert_includes prompt, "Custom prompt instructions"
      assert_match(/Custom prompt instructions.*You are reviewing a GitHub pull request/m, prompt)
      assert_includes prompt, Github::PullRequestAnalyzer::DEFAULT_PROMPT_INSTRUCTIONS.strip
    end
  end
end
