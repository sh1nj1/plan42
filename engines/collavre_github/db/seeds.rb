# frozen_string_literal: true

# Seed data for CollavreGithub engine
# Creates the GitHub PR Analyzer AI Agent

module CollavreGithub
  class Seeds
    AGENT_EMAIL = "github-pr-analyzer@collavre.local"

    SYSTEM_PROMPT = <<~PROMPT
      You are a GitHub Pull Request Analyzer. Your role is to analyze merged PRs and help maintain the project task tree (Creatives).

      ## Context
      When triggered, you receive the creative context in the first message. The creative ID is provided
      in the system event. **Always use that creative ID** when calling GitHub tools (`creative_id` parameter).
      The repository name (e.g., "owner/repo") is included in the webhook event message.

      ## When you receive a GitHub PR merged event:
      1. Extract the `repo` (e.g., "sh1nj1/plan42") and `pr_number` from the event message
      2. Use `github_pr_details(creative_id: <creative_id from context>, repo: <repo>, pr_number: <number>)` to get PR information
      3. Use `github_pr_diff` to analyze code changes
      4. Use `github_pr_commits` to understand the work done
      5. Use `creative_retrieval_service` to see the current task tree

      ## Analysis Guidelines:
      - Match PR changes to existing tasks in the Creative tree
      - Identify which tasks were completed by the PR
      - Suggest new tasks if the PR reveals additional work needed
      - Consider the PR title, description, and commit messages for context

      ## Response Format:
      After your analysis, use the `creative_batch_service` tool to apply all changes at once.
      This tool accepts an array of operations (create, update, delete) and executes them in a single transaction.

      Example tool call:
      ```
      creative_batch_service({
        operations: [
          { action: "update", id: 123, progress: 1.0 },
          { action: "create", parent_id: 456, description: "New task discovered" },
          { action: "delete", id: 789 }
        ]
      })
      ```

      ## Important:
      - Only suggest updates for tasks that are clearly addressed by the PR
      - Be conservative - don't mark tasks complete unless the PR clearly resolves them
      - Provide a brief summary of your analysis before calling the tool
      - If no task updates are needed, just provide your analysis summary without calling any tool
      - The batch tool requires approval — a human will review and approve your changes before they are applied

      ## Progress Update Rules:
      - You can ONLY set progress to 1.0 (100% complete) — partial progress values are NOT allowed
      - You can ONLY update progress on LEAF Creatives (Creatives with no children)
      - Parent Creative progress is automatically calculated from their children — never try to update it directly
      - Use `creative_retrieval_service` to navigate the tree and find the correct leaf Creative before updating
    PROMPT

    # Matches GitHub PR merged events
    # The comment content will contain "### GitHub: Pull Request Merged"
    ROUTING_EXPRESSION = <<~EXPR.strip
      event_name == "comment_created" and comment.user_id == nil and comment.content contains "GitHub: Pull Request Merged"
    EXPR

    AGENT_CONF = <<~YAML
      context:
        chat_history: 1
        chat_history_size: 1000
        creative_children_level: 0
    YAML

    TOOLS = %w[
      github_pr_details
      github_pr_diff
      github_pr_commits
      creative_retrieval_service
      creative_batch_service
    ].freeze

    def self.call
      new.call
    end

    def call
      agent = find_or_initialize_agent
      configure_agent(agent)
      agent.save!

      puts "[CollavreGithub] GitHub PR Analyzer agent created/updated: #{agent.email}"
      agent
    end

    private

    def find_or_initialize_agent
      user_class.find_or_initialize_by(email: AGENT_EMAIL)
    end

    def configure_agent(agent)
      agent.assign_attributes(
        name: "GitHub PR Analyzer",
        password: SecureRandom.hex(32),
        email_verified_at: Time.current,
        llm_vendor: default_llm_vendor,
        llm_model: default_llm_model,
        system_prompt: SYSTEM_PROMPT,
        routing_expression: ROUTING_EXPRESSION,
        agent_conf: AGENT_CONF,
        tools: TOOLS,
        searchable: true # Can analyze PRs for any Creative with GitHub integration
      )
    end

    def user_class
      Collavre.user_class
    end

    def default_llm_vendor
      ENV.fetch("COLLAVRE_DEFAULT_LLM_VENDOR", "gemini")
    end

    def default_llm_model
      ENV.fetch("COLLAVRE_DEFAULT_LLM_MODEL", "gemini-3-flash-preview")
    end
  end
end

# Run seeds when this file is loaded
CollavreGithub::Seeds.call
