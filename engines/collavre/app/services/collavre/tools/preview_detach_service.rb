module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Mark a previously-attached preview as stopped. AI Agents call this
  # immediately before killing the preview server (per the worktree cleanup
  # workflow) so the chip flips to the "stopped" badge with reduced opacity.
  # The chip stays visible until the user dismisses it with the X button —
  # mirrors the PR-channel post-close UX where the closed badge persists for
  # context.
  class PreviewDetachService
    extend T::Sig
    extend ToolMeta

    tool_name "preview_detach"
    tool_description <<~DESC.strip
      Mark a development preview as stopped. The chip stays visible with a
      stopped badge until the user dismisses it. Idempotent — calling on an
      already-stopped or missing channel returns ok with status :noop.
    DESC

    tool_param :topic_id, description: "The Collavre topic id the preview was attached to."
    tool_param :worktree_id, description: "The worktree_id used when the preview was attached."

    sig do
      params(
        topic_id: Integer,
        worktree_id: String
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(topic_id:, worktree_id:)
      topic = Collavre::Topic.find(topic_id)
      Collavre::Tools::TopicAuthorizer.authorize_write!(topic)

      channel = lookup_channel(topic, worktree_id)
      return { ok: true, status: :noop, worktree_id: worktree_id } if channel.nil?

      status =
        if channel.preview_state == "stopped" && channel.detached?
          :noop
        else
          channel.preview_state = "stopped"
          channel.state = :detached unless channel.detached?
          channel.save!
          :stopped
        end

      { ok: true, channel_id: channel.id, worktree_id: worktree_id, status: status }
    end

    private

    sig { params(topic: Collavre::Topic, worktree_id: String).returns(T.nilable(Collavre::PreviewChannel)) }
    def lookup_channel(topic, worktree_id)
      Collavre::PreviewChannel.where(topic_id: topic.id).find do |c|
        c.worktree_id.to_s == worktree_id.to_s
      end
    end
  end
end
end
