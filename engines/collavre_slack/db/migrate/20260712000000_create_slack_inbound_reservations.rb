class CreateSlackInboundReservations < ActiveRecord::Migration[8.0]
  def change
    # Pre-flight claim for an inbound Slack message. SlackInboundMessageJob inserts
    # a reservation row before running the non-idempotent CommandProcessor, so under
    # concurrent/redelivered delivery of the same message only the row's winner runs
    # the commands. The unique (slack_channel_link_id, message_ts) index is the
    # atomic gate — the same key the completed comment link uses, but claimed up
    # front rather than after the side effects.
    create_table :slack_inbound_reservations do |t|
      t.references :slack_channel_link, null: false, foreign_key: { on_delete: :cascade }
      t.string :message_ts, null: false

      t.timestamps
    end

    add_index :slack_inbound_reservations, [ :slack_channel_link_id, :message_ts ],
      unique: true, name: "idx_slack_inbound_reservations_on_channel_and_ts"
  end
end
