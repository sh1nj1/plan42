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
      paths = Creatives::PathExporter.new(creative).paths
      return if paths.blank?

      repo_full_name = payload.dig("repository", "full_name")
      pr = payload["pull_request"]
      client = Github::Client.new(link.github_account)
      commit_messages = client.pull_request_commit_messages(repo_full_name, pr["number"])
      diff = client.pull_request_diff(repo_full_name, pr["number"])

      analyzer = Github::PullRequestAnalyzer.new(
        payload: payload,
        creative: creative,
        paths: paths,
        commit_messages: commit_messages,
        diff: diff
      )
      result = analyzer.call
      return unless result

      create_comment(creative, result)
    end

    def create_comment(creative, result)
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
        result.completed.each { |path| lines << "- #{path}" }
      else
        lines << "- 없음"
      end
      lines << ""
      lines << "#### 추가로 필요한 Creative"
      if result.additional.any?
        result.additional.each { |path| lines << "- #{path}" }
      else
        lines << "- 없음"
      end
      lines << ""
      lines << "<details><summary>Gemini 응답 원문</summary>"
      lines << ""
      lines << "```json"
      lines << result.raw_response.strip
      lines << "```"
      lines << ""
      lines << "</details>"

      creative.comments.create!(user: nil, content: lines.join("\n"))
    end
  end
end
