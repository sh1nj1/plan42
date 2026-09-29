require "test_helper"

class CollavreGithubToolCategoryRegistrationTest < ActiveSupport::TestCase
  test "github tools are grouped under the GitHub category" do
    assert_equal :github, Collavre::McpToolCategories.key_for("github_pr_diff")
    assert_equal :github, Collavre::McpToolCategories.key_for("pr_monitor")

    group = Collavre::McpToolCategories.group([ { name: "pr_state_set" } ]).first
    assert_equal I18n.t("collavre_github.tool_category"), group[:label]
  end
end
