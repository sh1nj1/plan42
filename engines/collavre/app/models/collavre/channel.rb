module Collavre
  class Channel < ApplicationRecord
    BOT_EMAIL = "channel@collavre.local"
    BOT_NAME = "Channel"

    self.table_name = "channels"

    belongs_to :topic, class_name: "Collavre::Topic"

    enum :state, { active: 0, detached: 1 }, default: :active

    scope :not_dismissed, -> { where(dismissed_at: nil) }

    def handle(event:, payload:)
      raise NotImplementedError, "#{self.class} must implement #handle"
    end

    # Chip fallbacks rendered before any webhook event populates latest_label /
    # latest_link. Base class returns nil; subclasses override when they can
    # derive a stable label/link from their own config (e.g. PR #N + URL).
    def default_label
      nil
    end

    def default_link
      nil
    end

    # Badge interface for the typing-indicator chip. Subclasses override
    # `badge_state` to drive the chip badge color (the value becomes a CSS
    # modifier: channel-chip-badge--<state>), and `badge_title` to provide a
    # localized title / aria-label string. Returning nil from `badge_state`
    # hides the badge entirely.
    def badge_state
      nil
    end

    def badge_title
      nil
    end

    def detach!
      update!(state: :detached)
    end

    def dismissed?
      dismissed_at.present?
    end

    # Hide the chip from the typing-indicator row. Performs detach! as a
    # side-effect when the channel is still active so dismissal is a single
    # user-facing action — clicking the X always removes the chip regardless
    # of prior state.
    def dismiss!
      transaction do
        detach! if active?
        update!(dismissed_at: Time.current) if dismissed_at.nil?
      end
    end

    def record_event!(label:, link:)
      update!(latest_label: label, latest_link: link, last_event_at: Time.current)
    end

    def inject_into_topic!(injected_message)
      transaction do
        comment = topic.creative.comments.create!(
          user: injected_message.speaker,
          topic_id: topic.id,
          content: injected_message.message,
          private: false
        )
        record_event!(label: injected_message.label, link: injected_message.link)
        comment
      end
    end

    after_create_commit  :broadcast_chips_changed
    after_update_commit  :broadcast_chips_changed

    private

    def broadcast_chips_changed
      Collavre::CommentsPresenceChannel.broadcast_channel_chips_changed(topic.creative_id, topic_id: topic_id)
    end
  end
end
