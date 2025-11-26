require "json"

module Github
  class PullRequestProcessor
    HANDLED_ACTIONS = %w[closed].freeze

    def initialize(payload:, logger: Rails.logger)
      @payload = payload
      @logger = logger
    end

    def call
      action = payload["action"]
      return unless HANDLED_ACTIONS.include?(action)

      pr = payload["pull_request"]
      return unless pr
      return unless pr["merged"]

      repo_full_name = payload.dig("repository", "full_name")
      return unless repo_full_name

      links = GithubRepositoryLink.includes(:creative).where(repository_full_name: repo_full_name)
      return if links.blank?

      links.each do |link|
        process_link(link)
      end
    rescue StandardError => e
      logger.error("GitHub PR processing failed: #{e.class} #{e.message}")
    end

    private

    attr_reader :payload, :logger

    def process_link(link)
      creative = link.creative.effective_origin
      path_exporter = Creatives::PathExporter.new(creative, use_effective_origin: false)
      tree_entries = path_exporter.full_paths_with_ids_and_progress_with_leaf
      return if tree_entries.blank?

      repo_full_name = payload.dig("repository", "full_name")
      pr = payload["pull_request"]
      client = Github::Client.new(link.github_account)
      commit_messages = client.pull_request_commit_messages(repo_full_name, pr["number"])
      diff = client.pull_request_diff(repo_full_name, pr["number"])

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: tree_entries,
        commit_messages: commit_messages,
        diff: diff
      )
      result = analyzer.call
      return unless result

      create_comment(creative, link, path_exporter, result)
    end

    def create_comment(creative, link, path_exporter, result)
      pr = payload["pull_request"]
      title = pr["title"]
      number = pr["number"]
      url = pr["html_url"]

      lines = []
      lines << "### Github PR 분석"
      lines << "- PR: [##{number} #{title}](#{url})"
      lines << ""
      lines << "#### 완료된 Creative"
      if result.completed.any?
        result.completed.each do |task|
          lines << "- #{format_completed_task(task, path_exporter)}"
        end
      else
        lines << "- 없음"
      end
      lines << ""
      lines << "#### 추가로 필요한 Creative"
      if result.additional.any?
        result.additional.each do |suggestion|
          lines << "- #{format_suggestion(suggestion, path_exporter)}"
        end
      else
        lines << "- 없음"
      end

      actions = build_actions(result)
      if actions.any?
        lines << ""
        lines << "#### 승인 시 자동 적용"
        lines << "- 이 댓글을 승인하면 완료된 Creative의 진행률이 업데이트되고 제안된 Creative가 생성됩니다."
      end
      if result.prompt.present?
        lines << ""
        lines << "<details><summary>Gemini 전송 메시지</summary>"
        lines << ""
        lines << "```"
        lines << result.prompt.strip
        lines << "```"
        lines << ""
        lines << "</details>"
      end

      lines << ""
      lines << "<details><summary>Gemini 응답 원문</summary>"
      lines << ""
      lines << "```json"
      lines << result.raw_response.strip
      lines << "```"
      lines << ""
      lines << "</details>"

      attributes = { user: nil, content: lines.join("\n") }
      if actions.any?
        approver = link.github_account.user
        if approver
          attributes[:action] = JSON.pretty_generate({ actions: actions })
          attributes[:approver] = approver
        else
          logger.warn("Skipping action assignment for PR comment because approver is missing")
        end
      end

      creative.comments.create!(attributes)
    end

    def build_actions(result)
      actions = []

      result.completed.each do |task|
        next unless task.creative_id

        actions << {
          "action" => "update_creative",
          "creative_id" => task.creative_id,
          "attributes" => {
            "progress" => (task.progress || 1.0).to_f
          }
        }
      end

      result.additional.each do |suggestion|
        next unless suggestion.parent_id && suggestion.description.present?

        attributes = { "description" => suggestion.description }
        attributes["progress"] = suggestion.progress.to_f if suggestion.progress

        actions << {
          "action" => "create_creative",
          "parent_id" => suggestion.parent_id,
          "attributes" => attributes
        }
      end

      actions
    end

    def format_completed_task(task, path_exporter)
      label = task.path.presence || path_exporter.path_for(task.creative_id) || "Creative ##{task.creative_id}"
      parts = []
      parts << "#{creative_link(task.creative_id)} #{label}"
      if task.progress && task.progress < 1.0
        percentage = (task.progress * 100).round
        parts << "(progress #{percentage}%)"
      end
      parts << task.note if task.note.present?
      parts.join(" ")
    end

    def format_suggestion(suggestion, path_exporter)
      parent_label = path_exporter.path_for(suggestion.parent_id) || "Creative ##{suggestion.parent_id}"
      parts = []
      parts << "#{creative_link(suggestion.parent_id)} #{parent_label}"
      parts << "→ #{suggestion.description}"
      if suggestion.progress
        percentage = (suggestion.progress * 100).round
        parts << "(initial progress #{percentage}%)"
      end
      parts << "- #{suggestion.note}" if suggestion.note.present?
      parts.join(" ")
    end

    def creative_link(id)
      path = url_helpers.creative_path(id)
      "[#%<id>d](%<path>s)" % { id: id, path: path }
    rescue StandardError => e
      logger.warn("Failed to build creative link for ##{id}: #{e.message}")
      "##{id}"
    end

    def url_helpers
      @url_helpers ||= Rails.application.routes.url_helpers
    end
  end
end
