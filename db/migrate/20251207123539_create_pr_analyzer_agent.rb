class CreatePrAnalyzerAgent < ActiveRecord::Migration[7.0]
  def up
    user = User.find_or_initialize_by(email: "github-pr-analyzer@system.local")
    user.name = "GitHub PR Analyzer"
    user.password = SecureRandom.hex(16)

    # We use a Liquid template that defers to the Creative's template if present
    default_prompt = <<~PROMPT
      You are an expert software engineer and code reviewer.
      Your task is to review a GitHub Pull Request for a project that uses "Creatives" (tasks/files).

      Review the PR using the following context:

      PR Title: {{ context.pr_title }}
      PR Body: {{ context.pr_body }}

      Commit Messages:
      {{ context.commit_messages }}

      Diff:
      {{ context.diff }}

      Existing Creatives (File Tree):
      {{ context.creative_tree }}

      Instructions:
      1. Analyze the changes in the PR.
      2. Identify which existing Creatives are completed or modified.
      3. Suggest new Creatives that should be created based on the changes (e.g. tests, documentation, follow-up tasks).
      4. Output your response in the following JSON format:

      {
        "completed": [
          { "creative_id": 123, "progress": 1.0, "note": "Implemented feature X" }
        ],
        "additional": [
          { "parent_id": 123, "title": "Add tests for Feature X", "description": "Write unit tests coverage", "priority": "high" }
        ]
      }

      {{ context.language_instructions }}
    PROMPT

    # Use the Creative's template if available, otherwise use default
    user.system_prompt = "{{ creative.github_gemini_prompt_template | default: default_prompt_var }}"

    # But wait, passing a huge variable via Liquid variable lookup is tricky if it's not in context.
    # Actually, simpler approach:
    # Just set a reasonable default. If the user wants to use the creative's template,
    # we can make the System Agent's prompt be JUST:
    # {{ creative.github_gemini_prompt_template }}
    # And if that is empty, we handle it?
    # Or we can use `{% if creative.github_gemini_prompt_template != blank %}{{ creative.github_gemini_prompt_template }}{% else %}... default ...{% endif %}`

    user.system_prompt = <<~LIQUID
      {% if creative.github_gemini_prompt_template != blank %}
        {{ creative.github_gemini_prompt_template }}
      {% else %}
        #{default_prompt}
      {% endif %}
    LIQUID

    user.routing_expression = "event_name == 'github.pull_request'"
    user.llm_vendor = "google" # Default to Gemini
    user.llm_model = "gemini-1.5-flash-latest" # Faster, cheaper model
    user.save!
  end

  def down
    User.find_by(email: "github-pr-analyzer@system.local")&.destroy
  end
end
