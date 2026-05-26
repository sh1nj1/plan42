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
      "PR ##{pr_number}"
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
      verb = pr["merged"] ? "merged" : "closed"

      msg = Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: "#{label} was **#{verb}**. Detaching channel.",
        label: "#{label} (#{verb})",
        link: pr_url
      )
      detach!
      msg
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
        message: "**@#{author}** submitted a review (`#{state}`) on #{label}:\n\n#{body}",
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

      location = path ? " on `#{path}`#{line ? ":#{line}" : ''}" : ""
      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: "**@#{author}** reviewed #{label}#{location}:\n\n#{body}",
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
        message: "**@#{author}** commented on #{label}:\n\n#{body}",
        label: label,
        link: pr_url
      )
    end

    def ignored_actor?(login)
      Array(config["ignore_actor_logins"]).include?(login)
    end

    def channel_bot_user
      @channel_bot_user ||= Collavre::User.find_by!(email: Collavre::Channel::BOT_EMAIL)
    end
  end
end
