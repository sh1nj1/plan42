require "set"

class CreateContacts < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    create_table :contacts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :contact_user, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :contacts, [ :user_id, :contact_user_id ], unique: true

    backfill_contacts
  end

  def down
    drop_table :contacts
  end

  private

  def backfill_contacts
    say_with_time "Backfilling contacts from invitations and shares" do
      contact_rows = []
      timestamp = Time.current

      existing_contacts = Set.new

      invitation_pairs.each do |inviter_id, invitee_id|
        next if inviter_id == invitee_id
        key = [ inviter_id, invitee_id ]
        next if existing_contacts.include?(key)
        existing_contacts << key
        contact_rows << { user_id: inviter_id, contact_user_id: invitee_id, created_at: timestamp, updated_at: timestamp }
      end

      share_pairs.each do |owner_id, shared_user_id|
        next if owner_id == shared_user_id
        key = [ owner_id, shared_user_id ]
        next if existing_contacts.include?(key)
        existing_contacts << key
        contact_rows << { user_id: owner_id, contact_user_id: shared_user_id, created_at: timestamp, updated_at: timestamp }
      end

      return if contact_rows.empty?

      MigrationContact.insert_all(contact_rows)
    end
  end

  def invitation_pairs
    Invitation
      .joins("INNER JOIN users ON LOWER(users.email) = LOWER(invitations.email)")
      .pluck(:inviter_id, "users.id")
  end

  def share_pairs
    no_access = CreativeShare.permissions[:no_access]
    CreativeShare
      .joins(:creative)
      .where.not(permission: no_access)
      .pluck("creatives.user_id", :user_id)
  end

  class MigrationContact < ActiveRecord::Base
    self.table_name = "contacts"
  end
end
