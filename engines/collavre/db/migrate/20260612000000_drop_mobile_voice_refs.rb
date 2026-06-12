# frozen_string_literal: true

# The mobile voice companion no longer addresses work by spoken ordinal
# ("1번 승인"). The app now lists messages by Creative#Topic, the user taps to
# select, and replies route by event id / topic_id — so the per-(user, device)
# ordinal namespace this table owned is dead. Dropped with the RefRegistry /
# CommandResolver / IntentClassifier stack. (Reversible: re-runs the original
# CreateMobileVoiceRefs schema.)
class DropMobileVoiceRefs < ActiveRecord::Migration[8.0]
  def up
    drop_table :mobile_voice_refs, if_exists: true
  end

  def down
    create_table :mobile_voice_refs do |t|
      t.integer :user_id, null: false
      t.string  :device_id, null: false
      t.integer :ref_number, null: false
      t.integer :topic_id
      t.string  :kind, null: false
      t.integer :target_comment_id
      t.string  :request_id
      t.string  :status, null: false, default: "active"
      t.string  :label
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :mobile_voice_refs, [ :user_id, :device_id, :status ]
    add_index :mobile_voice_refs, [ :user_id, :device_id, :ref_number ],
              unique: true, name: "index_mobile_voice_refs_on_owner_and_number"
    add_index :mobile_voice_refs, :target_comment_id
  end
end
