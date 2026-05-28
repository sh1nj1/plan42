module Collavre
  # Topic chip for a running development preview server. Unlike
  # GithubPrChannel there is no external webhook source — the chip is
  # populated by AI Agents (or humans) calling preview_attach/preview_detach
  # MCP tools, one for each ./bin/dev they spin up alongside a worktree.
  class PreviewChannel < Collavre::Channel
    self.table_name = "channels"

    PREVIEW_STATES = %w[running stopped].freeze

    def preview_url
      config["preview_url"]
    end

    def worktree_id
      config["worktree_id"]
    end

    def custom_label
      config["label"]
    end

    # Chip fallbacks rendered immediately on attach, before the user has
    # interacted with the chip. The label prefers the caller-supplied
    # "Preview #42" style override and falls back to a localized default;
    # the link is always the preview URL.
    def default_label
      custom_label.presence || I18n.t("collavre.channel.preview.label_default")
    end

    def default_link
      preview_url
    end

    def badge_state
      preview_state
    end

    def badge_title
      I18n.t("collavre.channel.preview.badge.#{preview_state}", default: preview_state.to_s)
    end

    def preview_state
      state = config["preview_state"].to_s
      PREVIEW_STATES.include?(state) ? state : "running"
    end

    def preview_state=(value)
      value = value.to_s
      raise ArgumentError, "Invalid preview_state: #{value.inspect}" unless PREVIEW_STATES.include?(value)
      self.config = config.merge("preview_state" => value)
    end

    def attached_message
      Collavre::Channel::InjectedMessage.new(
        speaker: channel_bot_user,
        message: I18n.t("collavre.channel.preview.attached_message",
                        label: default_label, url: preview_url),
        label: default_label,
        link: preview_url
      )
    end

    # PreviewChannel has no external event source — preview_attach/detach
    # mutate the channel directly. The base `handle` would raise
    # NotImplementedError, so override with an explicit no-op.
    def handle(event:, payload:)
      nil
    end

    private

    # Same bot user as GithubPrChannel so all channel-injected comments come
    # from a single "Channel" speaker in the topic timeline.
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
