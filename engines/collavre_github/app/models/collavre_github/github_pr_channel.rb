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

    # PR lifecycle state used by the chip badge color. Defaults to "open" so
    # freshly attached channels render the green badge before any close event
    # has been received. Persisted in `config` to avoid a schema change for a
    # channel-subtype-specific concern.
    PR_STATES = %w[open merged closed_without_merge].freeze

    def pr_state
      state = config["pr_state"].to_s
      PR_STATES.include?(state) ? state : "open"
    end

    # Symmetric with the reader: refuse to persist values outside PR_STATES
    # rather than silently downgrading to "open" at read time. Without this
    # any caller that mistypes (e.g. "merged_") would corrupt the badge color
    # with no error surfaced.
    def pr_state=(value)
      value = value.to_s
      raise ArgumentError, "Invalid pr_state: #{value.inspect}" unless PR_STATES.include?(value)
      self.config = config.merge("pr_state" => value)
    end

    def attached_message
      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("attached_message", label: label, url: pr_url),
        label: label,
        link: pr_url
      )
    end

    def reopened_message
      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("reopened_message", label: label, url: pr_url),
        label: label,
        link: pr_url
      )
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
      new_state = pr["merged"] ? "merged" : "closed_without_merge"
      verb = pr["merged"] ? t("state_merged") : t("state_closed")

      # pr_state is updated atomically with the closing comment: the dispatch
      # path wraps both `handle` and `inject_into_topic!` in a single with_lock
      # transaction, so an inject failure rolls this update back too. That is
      # the intended behavior — we don't want the chip to flash merged/closed
      # without the matching closing message in the timeline.
      self.pr_state = new_state
      save!

      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: t("closed_message", label: label, verb: verb),
        label: label,
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
