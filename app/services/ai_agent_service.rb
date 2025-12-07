class AiAgentService
  def initialize(task)
    @task = task
    @agent = task.agent
    @context = task.trigger_event_payload
  end

  def call
    # Log start action
    log_action("start", { message: "Starting agent execution" })

    # Prepare messages for AI
    messages = build_messages

    # Log prompt generation
    log_action("prompt_generated", { messages: messages })

    # Call AI Client
    response_content = ""

    # Enrich context for rendering
    rendering_context = @context.dup
    if @context.dig("creative", "id")
      creative = Creative.find_by(id: @context["creative"]["id"])
      rendering_context["creative"] = creative.as_json if creative
    end

    rendered_system_prompt = AiSystemPromptRenderer.new(
      template: @agent.system_prompt,
      context: rendering_context
    ).render

    # we may pass event payload also to the AI client for more context if needed - TODO
    client = AiClient.new(
      vendor: @agent.llm_vendor,
      model: @agent.llm_model,
      system_prompt: rendered_system_prompt,
      llm_api_key: @agent.llm_api_key
    )

    client.chat(messages, tools: @agent.tools || []) do |delta|
      response_content += delta
      # We could stream updates to the task or a related comment here if needed
    end

    # Log completion
    log_action("completion", { response: response_content })

    # Handle the response (e.g., create a comment reply)
    if @context.dig("comment", "id") && response_content.present?
      reply_to_comment(@context["comment"]["id"], response_content)
    elsif @context["github_link_id"] && response_content.present?
      handle_github_response(response_content)
    end
  end

  private

  def log_action(type, payload, result = nil)
    @task.task_actions.create!(
      action_type: type,
      payload: payload,
      result: result,
      status: "done"
    )
  end

  def build_messages
    enrich_context_with_github_data if @context["github_link_id"]

    # This logic mimics the old AiResponder but adapts to the new context structure
    # We might need to fetch the creative and history based on context

    messages = []

    # Add context-specific messages
    # For comment_created, we want the creative context and chat history

    if @context["creative"]
      # We might need to re-fetch creative to get the full markdown if it's not in context
      # But for efficiency, let's assume we fetch it if ID is present
      creative_id = @context.dig("creative", "id")
      if creative_id
        creative = Creative.find_by(id: creative_id)
        if creative
          markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ], 1, true)
          messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }
        end
      end
    end

    # Add chat history
    if @context.dig("creative", "id")
      creative_id = @context["creative"]["id"]

      # Only fetch history for comment events, not PR events (unless we want PR to see comments?)
      # For now, keep history for comments.
      if @context.dig("comment", "id")
        Comment.where(creative_id: creative_id, private: false)
               .order(created_at: :desc)
               .limit(50) # Limit history to avoid context window issues
               .reverse # Re-order to chronological for the AI
               .each do |c|
          next if c.id == @context.dig("comment", "id")

          role = (c.user_id == @agent.id) ? "model" : "user"
          content = c.content

          # Strip mentions of the agent from user messages to clean up context
          if role == "user"
             if content.match?(/\A@#{Regexp.escape(@agent.name)}:/i)
               content = content.sub(/\A@#{Regexp.escape(@agent.name)}:\s*/i, "")
             elsif content.match?(/\A@#{Regexp.escape(@agent.name)}\s+/i)
               content = content.sub(/\A@#{Regexp.escape(@agent.name)}\s+/i, "")
             end
          end

          messages << { role: role, parts: [ { text: content } ] }
        end
      end
    end

    # Add the trigger payload
    # For GitHub events, the system prompt contains the instructions.
    # The payload (comment content) is added here for comment events.
    # For PR events, do we add anything as "user" message?
    # The system prompt has {{ context.diff }} etc.
    # So maybe we don't need a user message for PR events, OR we add a generic "Analyze this" message.

    if @context.dig("comment", "content")
      messages << { role: "user", parts: [ { text: @context["comment"]["content"] } ] }
    elsif @context["github_link_id"]
      # For PRs, the system prompt does the heavy lifting, but we need at least one user message usually?
      # Gemini usually expects a user message.
      messages << { role: "user", parts: [ { text: "Please analyze the Pull Request based on the provided context." } ] }
    else
      payload_text = @context.to_json
      messages << { role: "user", parts: [ { text: payload_text } ] }
    end

    messages
  end

  def reply_to_comment(comment_id, content)
    original_comment = Comment.find_by(id: comment_id)
    return unless original_comment

    reply = original_comment.creative.comments.create!(
      content: content,
      user: @agent
    )

    log_action("reply_created", { comment_id: reply.id, content: content })
  end

  def enrich_context_with_github_data
    link = GithubRepositoryLink.find_by(id: @context["github_link_id"])
    return unless link

    repo_full_name = @context.dig("repository", "full_name")
    pr_number = @context.dig("pull_request", "number")

    client = Github::Client.new(link.github_account)

    # Fetch Commits
    commit_messages = client.pull_request_commit_messages(repo_full_name, pr_number)
    formatted_commits = commit_messages.map.with_index(1) { |msg, i| "#{i}. #{msg.strip}" }.join("\n")

    # Fetch Diff
    diff = client.pull_request_diff(repo_full_name, pr_number).to_s
    if diff.length > 10_000
      diff = diff.slice(0, 10_000) + "\n... [Diff truncated]"
    end

    # Fetch Creative Tree
    creative = link.creative.effective_origin
    path_exporter = Creatives::PathExporter.new(creative, use_effective_origin: false)
    tree_entries = path_exporter.full_paths_with_ids_and_progress_with_leaf
    tree_lines = tree_entries.select { |e| e[:leaf] }.map { |e| "- #{e[:path]} [Leaf]" }.join("\n")

    # Language
    locale = creative.user&.locale || "en"
    lang_instructions = "Preferred response language: #{locale}. Write all natural-language output in #{locale}."

    # Update Context for Renderer
    @context["pr_title"] = @context.dig("pull_request", "title")
    @context["pr_body"] = @context.dig("pull_request", "body")
    @context["commit_messages"] = formatted_commits
    @context["diff"] = diff
    @context["creative_tree"] = tree_lines
    @context["language_instructions"] = lang_instructions

    # Also ensure creative is set for view logic usually
    @context["creative"] = creative.as_json
  end

  def handle_github_response(response_text)
    link = GithubRepositoryLink.find_by(id: @context["github_link_id"])
    return unless link
    creative = link.creative.effective_origin

    # Parse JSON
    json_match = response_text.match(/\{[\s\S]*\}/)
    data = {}
    if json_match
      begin
        data = JSON.parse(json_match[0])
      rescue JSON::ParserError
        Rails.logger.warn("Failed to parse Agent JSON response")
      end
    end

    # Build Markdown and Actions
    lines = []
    lines << "### GitHub PR Analysis"

    completed = data["completed"] || []
    additional = data["additional"] || []

    lines << "#### Completed Creatives"
    if completed.any?
      completed.each do |item|
        lines << "- Creative ##{item['creative_id']}: #{item['note']} (Progress: #{item['progress']})"
      end
    else
      lines << "- None"
    end

    lines << ""
    lines << "#### Suggested Creatives"
    if additional.any?
      additional.each do |item|
        lines << "- [New] #{item['title']}: #{item['description']} (Parent: ##{item['parent_id']})"
      end
    else
      lines << "- None"
    end

    lines << ""
    lines << "<details><summary>Raw Response</summary>\n\n```json\n#{response_text}\n```\n</details>"

    # Build Actions
    actions = []
    completed.each do |item|
      next unless item["creative_id"]
      actions << {
        "action" => "update_creative",
        "creative_id" => item["creative_id"],
        "attributes" => { "progress" => (item["progress"] || 1.0).to_f }
      }
    end

    additional.each do |item|
      next unless item["parent_id"] && item["title"]
      actions << {
        "action" => "create_creative",
        "parent_id" => item["parent_id"],
        "attributes" => { "description" => item["title"], "progress" => 0.0 }
      }
    end

    # Create Comment
    comment_attrs = { user: @agent, content: lines.join("\n") }
    if actions.any? && link.github_account.user
      comment_attrs[:action] = JSON.pretty_generate({ actions: actions })
      comment_attrs[:approver] = link.github_account.user
    end

    creative.comments.create!(comment_attrs)
    log_action("pr_comment_created", { creative_id: creative.id })
  end
end
