class MigrateActiveStorageAttachmentRecordTypes < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:active_storage_attachments)

    migrate_record_type("User", "Collavre::User")
    migrate_record_type("Comment", "Collavre::Comment")
  end

  def down
    return unless table_exists?(:active_storage_attachments)

    migrate_record_type("Collavre::User", "User")
    migrate_record_type("Collavre::Comment", "Comment")
  end

  private

  def migrate_record_type(from, to)
    ActiveStorage::Attachment.where(record_type: from).update_all(record_type: to)
  end
end
