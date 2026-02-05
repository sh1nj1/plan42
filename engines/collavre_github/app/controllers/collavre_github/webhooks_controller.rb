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
      create_system_comment(event, payload) if @repository_link&.creative

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def create_system_comment(event, payload)
      creative = @repository_link.creative.effective_origin
      content = format_github_event(event, payload)

      comment = creative.comments.create!(
        user: nil,
        content: content,
        private: false
      )

      # Dispatch event for AI Agent routing
      Collavre::SystemEvents::Dispatcher.dispatch("comment_created", {
        comment: {
          id: comment.id,
          content: comment.content,
          user_id: nil
        },
        creative: {
          id: creative.id,
          description: creative.description
        },
        chat: {
          content: comment.content
        }
      })
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

      lines = []
      lines << "### GitHub: Pull Request #{action_label(action, merged)}"
      lines << ""
      lines << "**Repository:** #{repo}"
      lines << "**PR:** [##{number} #{title}](#{url})"
      lines << "**Author:** #{user}"
      lines << "**Action:** #{action}#{merged ? ' (merged)' : ''}"

      if pr["body"].present?
        lines << ""
        lines << "**Description:**"
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

      lines = []
      lines << "### GitHub: Push to #{branch}"
      lines << ""
      lines << "**Repository:** #{repo}"
      lines << "**Branch:** #{branch}"
      lines << "**Pusher:** #{pusher}"
      lines << "**Commits:** #{commits.size}"

      if commits.any?
        lines << ""
        lines << "**Recent commits:**"
        commits.first(5).each do |commit|
          message = commit["message"].to_s.lines.first&.strip || "(no message)"
          sha = commit["id"].to_s[0, 7]
          lines << "- `#{sha}` #{message.truncate(80)}"
        end
        lines << "- ..." if commits.size > 5
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

      lines = []
      lines << "### GitHub: Issue #{action}"
      lines << ""
      lines << "**Repository:** #{repo}"
      lines << "**Issue:** [##{number} #{title}](#{url})"
      lines << "**Author:** #{user}"
      lines << "**Action:** #{action}"

      if action == "opened" && issue["body"].present?
        lines << ""
        lines << "**Description:**"
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

      lines = []
      lines << "### GitHub: Comment #{action} on Issue ##{number}"
      lines << ""
      lines << "**Repository:** #{repo}"
      lines << "**Issue:** ##{number} #{title}"
      lines << "**Comment by:** #{user}"
      lines << "**Link:** [View comment](#{url})"

      if comment["body"].present?
        lines << ""
        lines << "**Comment:**"
        lines << comment["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_generic_event(event, payload)
      repo = payload.dig("repository", "full_name")
      action = payload["action"]
      sender = payload.dig("sender", "login")

      lines = []
      lines << "### GitHub: #{event.titleize}"
      lines << ""
      lines << "**Repository:** #{repo}"
      lines << "**Action:** #{action}" if action
      lines << "**Sender:** #{sender}" if sender

      lines.join("\n")
    end

    def action_label(action, merged)
      case action
      when "opened"
        "Opened"
      when "closed"
        merged ? "Merged" : "Closed"
      when "reopened"
        "Reopened"
      when "synchronize"
        "Updated"
      when "ready_for_review"
        "Ready for Review"
      else
        action&.titleize || "Event"
      end
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
