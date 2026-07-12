module CollavreSlack
  # A pre-flight claim on an inbound Slack message, inserted by
  # SlackInboundMessageJob before it runs the non-idempotent CommandProcessor. The
  # unique (slack_channel_link_id, message_ts) index makes the claim atomic: of two
  # concurrent jobs for the same message, exactly one inserts a row and proceeds to
  # the side effects; the other trips the index and no-ops. See the job for the
  # crash-window trade-off.
  class SlackInboundReservation < ApplicationRecord
    self.table_name = "slack_inbound_reservations"

    belongs_to :slack_channel_link, class_name: "CollavreSlack::SlackChannelLink"

    validates :message_ts, presence: true
    validates :message_ts, uniqueness: { scope: :slack_channel_link_id }
  end
end
