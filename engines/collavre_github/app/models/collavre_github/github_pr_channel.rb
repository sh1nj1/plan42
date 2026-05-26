module CollavreGithub
  class GithubPrChannel < Collavre::Channel
    self.table_name = "channels"

    def repo_full_name
      config["repo_full_name"]
    end

    def pr_number
      config["pr_number"].to_i
    end

    def pr_url
      "https://github.com/#{repo_full_name}/pull/#{pr_number}"
    end

    def label
      t("label", number: pr_number)
    end

    def handle(event:, payload:)
      case event
      when "issue_comment"
        handle_issue_comment(payload)
      when "pull_request_review_comment"
        handle_review_comment(payload)
      when "pull_request_review"
        handle_review_submitted(payload)
      when "pull_request"
        handle_pull_request(payload)
      end
    end

    private

    def handle_pull_request(payload)
      return nil unless payload["action"] == "closed"
      pr = payload["pull_request"]
      verb_key = pr["merged"] ? "state_merged" : "state_closed"
      verb = t(verb_key)

      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("closed_message", label: label, verb: verb),
        label: t("label_with_state", label: label, state: verb),
        link: pr_url
      )
      # Detach is performed by the webhook controller AFTER injecting this
      # message, so the chip stays visible until the closing comment lands.
    end

    def handle_review_submitted(payload)
      return nil unless payload["action"] == "submitted"
      review = payload["review"]
      body = review["body"].to_s
      return nil if body.strip.empty?

      author = review.dig("user", "login")
      return nil if ignored_actor?(author)
      state = review["state"]
      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("review_submitted_message", author: author, state: state, label: label, body: body),
        label: label,
        link: pr_url
      )
    end

    def handle_review_comment(payload)
      return nil unless payload["action"] == "created"
      comment = payload["comment"]
      author = comment.dig("user", "login")
      return nil if ignored_actor?(author)
      path = comment["path"]
      line = comment["line"]
      body = comment["body"].to_s

      location =
        if path && line
          t("review_comment_location_path_line", path: path, line: line)
        elsif path
          t("review_comment_location_path", path: path)
        else
          ""
        end
      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("review_comment_message", author: author, label: label, location: location, body: body),
        label: label,
        link: pr_url
      )
    end

    def handle_issue_comment(payload)
      return nil unless payload["action"] == "created"
      return nil unless payload.dig("issue", "pull_request") # PR comments only

      comment = payload["comment"]
      author = comment.dig("user", "login")
      return nil if ignored_actor?(author)
      body = comment["body"].to_s

      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("comment_message", author: author, label: label, body: body),
        label: label,
        link: pr_url
      )
    end

    def ignored_actor?(login)
      Array(config["ignore_actor_logins"]).include?(login)
    end

    def t(key, **opts)
      I18n.t("collavre_github.channel.pr.#{key}", **opts)
    end

    # Find the channel bot user. Falls back to creating the row when missing
    # (e.g. migrations applied but `db:seed` was skipped). Without this
    # fallback every PR webhook would raise RecordNotFound and the event
    # would be silently dropped by the controller's rescue.
    def channel_bot_user
      @channel_bot_user ||=
        Collavre::User.find_by(email: Collavre::Channel::BOT_EMAIL) ||
          ensure_channel_bot_user!
    end

    def ensure_channel_bot_user!
      email = Collavre::Channel::BOT_EMAIL
      user = Collavre::User.find_or_initialize_by(email: email)
      user.name = Collavre::Channel::BOT_NAME
      user.password = SecureRandom.hex(32) if user.new_record?
      user.email_verified_at ||= Time.current
      user.searchable = false if user.respond_to?(:searchable=)
      user.llm_vendor = nil
      user.save!
      user
    end
  end
end
