module CollavreSlack
  # Pre-flight claim on an inbound Slack message so its non-idempotent side effects
  # run once. The unique (slack_channel_link_id, message_ts) index makes the claim
  # atomic: of two concurrent jobs, only one inserts and proceeds. See the job for
  # the crash-window trade-off.
  class SlackInboundReservation < ApplicationRecord
    self.table_name = "slack_inbound_reservations"

    belongs_to :slack_channel_link, class_name: "CollavreSlack::SlackChannelLink"

    validates :message_ts, presence: true
    validates :message_ts, uniqueness: { scope: :slack_channel_link_id }
  end
end
