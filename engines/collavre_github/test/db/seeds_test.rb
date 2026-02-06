# frozen_string_literal: true

require "test_helper"
require_relative "../../db/seeds"

class CollavreGithub::SeedsTest < ActiveSupport::TestCase
  test "creates GitHub PR Analyzer agent" do
    # Clean up any existing agent
    Collavre::User.find_by(email: CollavreGithub::Seeds::AGENT_EMAIL)&.destroy

    agent = CollavreGithub::Seeds.call

    assert agent.persisted?
    assert_equal "GitHub PR Analyzer", agent.name
    assert_equal CollavreGithub::Seeds::AGENT_EMAIL, agent.email
    assert agent.ai_user?
    assert agent.searchable?
    assert agent.routing_expression.present?
    assert_includes agent.tools, "github_pr_details"
    assert_includes agent.tools, "github_pr_diff"
    assert_includes agent.tools, "github_pr_commits"
  end

  test "updates existing agent on re-run" do
    # Create agent first
    agent = CollavreGithub::Seeds.call
    original_id = agent.id

    # Update something
    agent.update!(name: "Old Name")

    # Re-run seeds
    updated_agent = CollavreGithub::Seeds.call

    assert_equal original_id, updated_agent.id
    assert_equal "GitHub PR Analyzer", updated_agent.name
  end

  test "routing expression matches GitHub PR merged events" do
    require "liquid"

    expression = CollavreGithub::Seeds::ROUTING_EXPRESSION
    template_expr = "{% if #{expression} %}true{% endif %}"
    template = Liquid::Template.parse(template_expr)

    # Should match PR merged event
    context = {
      "event_name" => "comment_created",
      "chat" => {
        "comment" => {
          "user_id" => nil,
          "content" => "### GitHub: Pull Request merged\n**Repository:** owner/repo"
        }
      }
    }
    assert_equal "true", template.render(context)

    # Should not match non-merged PR
    context["chat"]["comment"]["content"] = "### GitHub: Pull Request opened"
    assert_equal "", template.render(context)

    # Should not match user comments
    context["chat"]["comment"]["user_id"] = 123
    context["chat"]["comment"]["content"] = "### GitHub: Pull Request merged"
    assert_equal "", template.render(context)

    # Should not match other events
    context["event_name"] = "other_event"
    context["chat"]["comment"]["user_id"] = nil
    assert_equal "", template.render(context)
  end
end
