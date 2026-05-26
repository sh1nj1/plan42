module CollavreGithub
  class WebhooksController < ActionController::API
    def create
      event = github_event_header
      if event.blank?
        Rails.logger.warn("GitHub event header missing; rejecting request")
        return head :bad_request
      end

      raw_body = request.raw_post.presence || request.body.read
      payload = parse_payload(raw_body)
      @repository_link = find_repository_link(payload)
      return head :unauthorized unless valid_signature?(raw_body)

      payload = payload.presence || {}

      # Process all links for this repo (same repo can be linked to multiple creatives)
      all_links = all_repository_links_for(payload)
      all_links.each do |link|
        create_system_comment_for(link, event, payload) if link.creative
        trigger_markdown_sync_for(link, event, payload) if link.markdown_sync_enabled?
      end

      dispatch_to_channels(event, payload)

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def dispatch_to_channels(event, payload)
      repo = payload.dig("repository", "full_name")
      pr_number = extract_pr_number(event, payload)
      return if repo.blank? || pr_number.nil?

      # Ruby-level filter for DB portability (SQLite dev/test, Postgres prod).
      # Future optimization: switch to a jsonb-portable query once an established
      # pattern exists in this codebase.
      GithubPrChannel.active.find_each do |channel|
        next unless channel.repo_full_name == repo && channel.pr_number == pr_number

        injected = channel.handle(event: event, payload: payload)
        next if injected.nil?

        channel.inject_into_topic!(injected)
      end
    rescue => e
      Rails.logger.error("[CollavreGithub] channel dispatch failed: #{e.class}: #{e.message}")
    end

    def extract_pr_number(event, payload)
      case event
      when "issue_comment"
        n = payload.dig("issue", "number")
        n if payload.dig("issue", "pull_request")
      when "pull_request_review_comment", "pull_request_review", "pull_request"
        payload.dig("pull_request", "number")
      end
    end

    def create_system_comment_for(link, event, payload)
      creative = link.creative&.effective_origin
      return unless creative

      content = format_github_event(event, payload)

      creative.comments.create!(
        user: nil,
        content: content,
        private: false
      )
    end

    def format_github_event(event, payload)
      case event
      when "pull_request"
        format_pull_request(payload)
      when "push"
        format_push(payload)
      when "issues"
        format_issue(payload)
      when "issue_comment"
        format_issue_comment(payload)
      else
        format_generic_event(event, payload)
      end
    end

    def format_pull_request(payload)
      pr = payload["pull_request"] || {}
      action = payload["action"]
      number = pr["number"]
      title = pr["title"]
      url = pr["html_url"]
      user = pr.dig("user", "login")
      merged = pr["merged"]
      repo = payload.dig("repository", "full_name")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('pull_request.title', action: action_label(action, merged))}"
      lines << ""
      lines << "**#{t.call('pull_request.repository')}:** #{repo}"
      lines << "**#{t.call('pull_request.pr')}:** [##{number} #{title}](#{url})"
      lines << "**#{t.call('pull_request.author')}:** #{user}"
      lines << "**#{t.call('pull_request.action')}:** #{action}#{merged ? " #{t.call('pull_request.merged')}" : ''}"

      if pr["body"].present?
        lines << ""
        lines << "**#{t.call('pull_request.description')}:**"
        lines << pr["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_push(payload)
      repo = payload.dig("repository", "full_name")
      ref = payload["ref"]
      branch = ref&.sub("refs/heads/", "")
      pusher = payload.dig("pusher", "name")
      commits = payload["commits"] || []
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('push.title', branch: branch)}"
      lines << ""
      lines << "**#{t.call('push.repository')}:** #{repo}"
      lines << "**#{t.call('push.branch')}:** #{branch}"
      lines << "**#{t.call('push.pusher')}:** #{pusher}"
      lines << "**#{t.call('push.commits')}:** #{commits.size}"

      if commits.any?
        lines << ""
        lines << "**#{t.call('push.recent_commits')}:**"
        commits.first(5).each do |commit|
          message = commit["message"].to_s.lines.first&.strip || t.call("push.no_message")
          sha = commit["id"].to_s[0, 7]
          lines << "- `#{sha}` #{message.truncate(80)}"
        end
        lines << "- #{t.call('push.more')}" if commits.size > 5
      end

      lines.join("\n")
    end

    def format_issue(payload)
      issue = payload["issue"] || {}
      action = payload["action"]
      number = issue["number"]
      title = issue["title"]
      url = issue["html_url"]
      user = issue.dig("user", "login")
      repo = payload.dig("repository", "full_name")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('issue.title', action: action)}"
      lines << ""
      lines << "**#{t.call('issue.repository')}:** #{repo}"
      lines << "**#{t.call('issue.issue')}:** [##{number} #{title}](#{url})"
      lines << "**#{t.call('issue.author')}:** #{user}"
      lines << "**#{t.call('issue.action')}:** #{action}"

      if action == "opened" && issue["body"].present?
        lines << ""
        lines << "**#{t.call('issue.description')}:**"
        lines << issue["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_issue_comment(payload)
      issue = payload["issue"] || {}
      comment = payload["comment"] || {}
      action = payload["action"]
      number = issue["number"]
      title = issue["title"]
      url = comment["html_url"]
      user = comment.dig("user", "login")
      repo = payload.dig("repository", "full_name")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('issue_comment.title', action: action, number: number)}"
      lines << ""
      lines << "**#{t.call('issue_comment.repository')}:** #{repo}"
      lines << "**#{t.call('issue_comment.issue')}:** ##{number} #{title}"
      lines << "**#{t.call('issue_comment.comment_by')}:** #{user}"
      lines << "**#{t.call('issue_comment.link')}:** [#{t.call('issue_comment.view_comment')}](#{url})"

      if comment["body"].present?
        lines << ""
        lines << "**#{t.call('issue_comment.comment')}:**"
        lines << comment["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_generic_event(event, payload)
      repo = payload.dig("repository", "full_name")
      action = payload["action"]
      sender = payload.dig("sender", "login")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('generic.title', event: event.titleize)}"
      lines << ""
      lines << "**#{t.call('generic.repository')}:** #{repo}"
      lines << "**#{t.call('generic.action')}:** #{action}" if action
      lines << "**#{t.call('generic.sender')}:** #{sender}" if sender

      lines.join("\n")
    end

    def action_label(action, merged)
      t = method(:t_webhook)
      case action
      when "opened"
        t.call("actions.opened")
      when "closed"
        merged ? t.call("actions.merged") : t.call("actions.closed")
      when "reopened"
        t.call("actions.reopened")
      when "synchronize"
        t.call("actions.updated")
      when "ready_for_review"
        t.call("actions.ready_for_review")
      else
        action&.titleize || t.call("actions.event")
      end
    end

    def t_webhook(key, **options)
      I18n.t("collavre_github.webhooks.#{key}", **options)
    end

    def trigger_markdown_sync_for(link, event, payload)
      return unless event == "push"

      CollavreGithub::MarkdownSyncJob.perform_later(
        link.id,
        payload.as_json
      )
    end

    def all_repository_links_for(payload)
      repo = payload&.dig("repository", "full_name") || payload&.dig(:repository, :full_name)
      return [ @repository_link ].compact if repo.blank?

      CollavreGithub::RepositoryLink.where(repository_full_name: repo).to_a
    end

    def find_repository_link(payload)
      if payload.blank?
        Rails.logger.warn("[GitHub Webhook] Payload is blank")
        return
      end

      repo = payload["repository"] || payload[:repository]
      if repo.blank?
        Rails.logger.warn("[GitHub Webhook] Repository missing in payload")
        return
      end

      full_name = repo["full_name"] || repo[:full_name]
      if full_name.blank?
        Rails.logger.warn("[GitHub Webhook] Repository full_name missing in payload")
        return
      end

      CollavreGithub::RepositoryLink.find_by(repository_full_name: full_name)
    end

    def valid_signature?(raw_body)
      secret = webhook_secret
      signature_header = request.headers["X-Hub-Signature-256"] || request.headers["X-Hub-Signature"]

      if secret.blank?
        Rails.logger.warn("GitHub webhook secret missing; rejecting request")
        return false
      end

      return false if signature_header.blank?

      algorithm =
        if signature_header.start_with?("sha256=")
          "sha256"
        elsif signature_header.start_with?("sha1=")
          "sha1"
        end

      return false if algorithm.blank?

      digest = OpenSSL::HMAC.hexdigest(algorithm.upcase, secret, raw_body)
      expected_signature = "#{algorithm}=#{digest}"

      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature_header)
    end

    def webhook_secret
      @repository_link&.webhook_secret || fallback_webhook_secret
    end

    def fallback_webhook_secret
      ENV["GITHUB_WEBHOOK_SECRET"] || Rails.application.credentials.dig(:github, :webhook_secret)
    end

    def parse_payload(raw_body)
      params = request.request_parameters
      parsed_params =
        case params
        when ActionController::Parameters
          params.to_unsafe_h
        else
          params
        end

      if parsed_params.present?
        wrapper_payload = parsed_params.with_indifferent_access[:payload]
        return wrapper_payload if wrapper_payload.is_a?(Hash)
        return JSON.parse(wrapper_payload) if wrapper_payload.is_a?(String)

        return parsed_params
      end

      raw_body.present? ? JSON.parse(raw_body) : nil
    end

    def github_event_header
      request.headers["X-GitHub-Event"].presence ||
        request.get_header("HTTP_X_GITHUB_EVENT").presence
    end
  end
end
