module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Attach a development-preview chip to a topic. AI Agents call this after
  # spinning up `./bin/dev` against a worktree so the preview URL and run
  # state surface as a chip in the typing-indicator row. Idempotent by
  # (topic_id, worktree_id).
  class PreviewAttachService
    extend T::Sig
    extend ToolMeta

    tool_name "preview_attach"
    tool_description <<~DESC.strip
      Attach a development preview server to a Collavre topic. Renders a
      chip in the topic's typing-indicator row with a clickable link to the
      preview URL and a state badge (running/stopped). Call this after
      starting a preview server (e.g. ./bin/dev on a worktree). Idempotent
      per (topic_id, worktree_id) — calling twice does not duplicate the
      chip or re-announce.
    DESC

    tool_param :topic_id, description: "The Collavre topic id to attach the preview chip to."
    tool_param :preview_url, description: "Full URL of the preview server, e.g. http://localhost:4001"
    tool_param :worktree_id, description: "Stable identifier for the worktree (or environment) running this preview. Used as the dedup key — re-calling with the same worktree_id reactivates the existing chip instead of creating a duplicate."
    tool_param :label, description: "Optional display label shown on the chip. Defaults to a localized 'Preview' string.", required: false

    sig do
      params(
        topic_id: Integer,
        preview_url: String,
        worktree_id: String,
        label: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(topic_id:, preview_url:, worktree_id:, label: nil)
      validate_preview_url!(preview_url)

      topic = Collavre::Topic.find(topic_id)
      Collavre::Tools::TopicAuthorizer.authorize_write!(topic)

      refresh_config = ->(c) {
        # Re-attach against the same worktree may carry a fresh URL/label
        # (e.g. port reassignment after a restart). Refresh the persisted
        # config so the chip link goes to the live server, not the dead one
        # — applies both when reactivating a stopped chip and when the chip
        # is still active (:noop), which is the common dev-restart case.
        new_config = c.config.merge(
          "preview_url" => preview_url,
          "preview_state" => "running"
        )
        new_config["label"] = label if label
        c.config = new_config
        # Also refresh the cached chip fields that record_event! seeded on the
        # first attach. The chip partial renders latest_link.presence ||
        # default_link, so without this update a :noop reattach with a new port
        # leaves the chip pointing at the dead URL even though config is fresh.
        # (On :reactivate the subsequent inject_into_topic! would overwrite
        # these via record_event! anyway, so updating here is harmless.)
        c.latest_link = preview_url
        c.latest_label = c.default_label
      }

      channel, status = Collavre::ChannelAttacher.call(
        channel_class: Collavre::PreviewChannel,
        lookup: -> { lookup_channel(topic, worktree_id) },
        create_attrs: {
          topic_id: topic.id,
          config: {
            "worktree_id" => worktree_id,
            "preview_url" => preview_url,
            "preview_state" => "running",
            "label" => label
          }.compact
        },
        on_reactivate: refresh_config,
        on_noop: refresh_config
      )

      # Mirror PR-channel UX: only the first attach (and a true reactivation
      # from stopped/dismissed) announces in the topic. Subsequent idempotent
      # attaches stay silent so frequent restarts do not spam the timeline.
      if status == :created || status == :reactivated
        channel.inject_into_topic!(channel.attached_message)
      end

      {
        ok: true,
        channel_id: channel.id,
        worktree_id: worktree_id,
        preview_url: preview_url,
        status: status
      }
    end

    private

    ALLOWED_PREVIEW_URL_SCHEMES = %w[http https].freeze
    private_constant :ALLOWED_PREVIEW_URL_SCHEMES

    # The preview_url is rendered directly as the chip's <a href> via ERB,
    # which escapes quotes but does NOT reject dangerous URL schemes. Without
    # this gate a write-capable MCP caller could persist `javascript:...` or
    # `data:...` and turn the chip into a one-click XSS for any topic viewer.
    sig { params(preview_url: String).void }
    def validate_preview_url!(preview_url)
      uri = URI.parse(preview_url)
      unless ALLOWED_PREVIEW_URL_SCHEMES.include?(uri.scheme&.downcase)
        raise ArgumentError, "preview_url must be http(s); got: #{preview_url.inspect}"
      end
      raise ArgumentError, "preview_url must include a host" if uri.host.to_s.empty?
    rescue URI::InvalidURIError
      raise ArgumentError, "preview_url is not a valid URI: #{preview_url.inspect}"
    end

    # config is JSON, so worktree_id matching is a Ruby-side scan over the
    # topic's preview channels. With only a handful of previews per topic in
    # practice this is fine and avoids JSON operator divergence between
    # Postgres (config->>'worktree_id') and SQLite (json_extract).
    sig { params(topic: Collavre::Topic, worktree_id: String).returns(T.nilable(Collavre::PreviewChannel)) }
    def lookup_channel(topic, worktree_id)
      Collavre::PreviewChannel.where(topic_id: topic.id).find do |c|
        c.worktree_id.to_s == worktree_id.to_s
      end
    end
  end
end
end
