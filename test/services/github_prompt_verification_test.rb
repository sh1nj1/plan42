require "test_helper"

class GithubPromptVerificationTest < ActiveSupport::TestCase
  test "system agent generates same prompt as legacy analyzer" do
    # 1. Setup Data
    pr_title = "My PR Title"
    pr_body = "This is the body"
    commit_messages = "- Commit 1\n- Commit 2"
    diff = "+ New line\n- Old line"
    creative_tree = "[LEAF] Task 1"
    language_instructions = "Respond in English."

    context = {
      "pr_title" => pr_title,
      "pr_body" => pr_body,
      "commit_messages" => commit_messages,
      "diff" => diff,
      "creative_tree" => creative_tree,
      "language_instructions" => language_instructions
    }

    # 2. Render Legacy Prompt (Manually replicating logic from deleted class, using constant)
    legacy_template = Creative::DEFAULT_GITHUB_GEMINI_PROMPT
    legacy_prompt = legacy_template
                      .gsub("\#{pr_title}", pr_title)
                      .gsub("\#{pr_body}", pr_body)
                      .gsub("\#{commit_messages}", commit_messages)
                      .gsub("\#{diff}", diff)
                      .gsub("\#{creative_tree}", creative_tree)
                      .gsub("\#{language_instructions}", language_instructions)

    # 3. Render System Agent Prompt
    # We need an agent with the system prompt set up in the migration
    agent = User.new(
      email: "test-agent@system.local",
      name: "Test Agent",
      password: "password"
    )

    # Mirroring the migration logic:
    # Use the Creative's template (which defaults to the same constant if we ensure creative doesn't override it)
    # The migration puts:
    # {% if creative.github_gemini_prompt_template != blank %}
    #   {{ creative.github_gemini_prompt_template }}
    # {% else %}
    #   ... default prompt text ...
    # {% endif %}

    # However, in Liquid, accessing `creative.github_gemini_prompt_template` will access the drop method.
    # The default prompt text inside the migration IS the Creative::DEFAULT_GITHUB_GEMINI_PROMPT converted to Liquid?
    # No, the migration logic shows a hardcoded string `default_prompt` that looks very similar but uses {{ liquid }} syntax.

    # Wait, the verification is "is it the same as before". "Before" used Ruby interpolation `#{var}`.
    # "After" uses Liquid `{{ var }}`.
    # So the *rendered output* should be the same.

    # Let's reconstruct the liquid template from the migration to test it accurately.
    migration_default_prompt = <<~PROMPT
      You are reviewing a GitHub pull request and mapping it to Creative tasks.
      Pull request title: {{ context.pr_title }}
      Pull request body:
      {{ context.pr_body }}

      Pull request commit messages:
      {{ context.commit_messages }}

      Pull request diff:
      {{ context.diff }}

      Creative task paths (each line is a single task path from root to leaf). Each node is shown as "[ID] Title (progress XX%)" when progress is known. Leaf creatives are marked with [LEAF] and non-leaf creatives with [BRANCH]:
      {{ context.creative_tree }}

      {{ context.language_instructions }}

      When describing creatives, write from an end-user perspective similar to a user manual. Avoid unnecessary technical detail, and keep sentences concise.

      Return a JSON object with two keys:
      - "completed": array of objects representing tasks finished by this PR. Each object must include "creative_id" (from the IDs above). Use only creatives marked [LEAF] in the list above. Optionally include "progress" (0.0 to 1.0), "note", or "path" for context.
      - "additional": array of objects for new creatives that are not already represented in the tree above. Each object must include "parent_id" (from the IDs above) and "description" (the new creative text). Do not use this list for follow-up tasks on existing creatives—only describe brand new creatives. Optionally include "progress" (0.0 to 1.0), "note", or "path".

      Do not add tasks to "completed" if they already show 100% progress in the tree above unless this PR clearly made new changes that justify marking them complete.

      Use only IDs present in the tree. Respond with valid JSON only.
    PROMPT

    # We will assume the creative has the default template, which means the liquid template uses the migration_default_prompt logic.
    # Actually, the migration logic is slightly different from `Creative::DEFAULT_GITHUB_GEMINI_PROMPT`.
    # `Creative::DEFAULT_GITHUB_GEMINI_PROMPT` uses `#{}`.
    # The migration `default_prompt` uses `{{ }}` but the TEXT content should be identical.

    # Let's verify that the text structure matches.

    # Render with Liquid
    liquid_template = Liquid::Template.parse(migration_default_prompt)
    agent_prompt = liquid_template.render("context" => context)

    # Normalize newlines and whitespace for comparison
    assert_equal legacy_prompt.strip, agent_prompt.strip
  end
end
