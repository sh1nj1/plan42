# frozen_string_literal: true

# Human-friendly stable reference numbers for the mobile voice companion.
# Collavre's internal identifiers (Topic.id, Comment.id, permission request_id
# UUIDs) are unspeakable over voice. The hands-free decision loop needs a short
# ordinal ("작업 1", "2번") that a person can SAY to point at a specific pending
# agent decision or running session — and that ordinal must stay pinned to the
# same target across polling cycles until it resolves, so "1번 승인" always means
# the same thing. This table owns that per-(user, device) ordinal namespace; it
# is the linchpin that makes "1번 승인/거절" resolve to a concrete approval.
class CreateMobileVoiceRefs < ActiveRecord::Migration[8.0]
  def change
    create_table :mobile_voice_refs do |t|
      t.integer :user_id, null: false
      t.string  :device_id, null: false                 # Device#client_id; refs are stable per device
      t.integer :ref_number, null: false                # the spoken ordinal (1,2,3…)
      t.integer :topic_id                               # the session/task this points at
      t.string  :kind, null: false                      # "approval" | "agent_session"
      t.integer :target_comment_id                      # permission Comment (kind=approval)
      t.string  :request_id                             # claude_channel_permission request_id
      t.string  :status, null: false, default: "active" # "active" | "resolved"
      t.string  :label                                  # short TTS/display name
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :mobile_voice_refs, [ :user_id, :device_id, :status ]
    add_index :mobile_voice_refs, [ :user_id, :device_id, :ref_number ],
              unique: true, name: "index_mobile_voice_refs_on_owner_and_number"
    add_index :mobile_voice_refs, :target_comment_id
  end
end
