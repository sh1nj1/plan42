# frozen_string_literal: true

namespace :storage do
  desc "Migrate local Active Storage files to S3 with user-prefixed keys"
  task migrate_to_s3: :environment do
    require "aws-sdk-s3"

    total = ActiveStorage::Blob.where(service_name: "local").count

    if total.zero?
      puts "No local blobs to migrate."
      exit
    end

    s3_service = ActiveStorage::Blob.services.fetch(:amazon)
    migrated = 0
    failed = 0
    skipped = 0

    puts "Migrating #{total} blobs from local to S3..."

    ActiveStorage::Blob.where(service_name: "local").find_each do |blob|
      # Determine owning user
      attachment = blob.attachments.first
      user_id = if attachment
                  case attachment.record_type
                  when "Collavre::Comment"
                    attachment.record&.user_id
                  when "Collavre::User"
                    attachment.record_id
                  end
      end

      new_key = if user_id
                  "users/#{user_id}/#{ActiveStorage::Blob.generate_unique_secure_token}"
      else
                  "unscoped/#{ActiveStorage::Blob.generate_unique_secure_token}"
      end

      begin
        blob.open do |tempfile|
          s3_service.upload(new_key, tempfile,
            checksum: blob.checksum,
            content_type: blob.content_type)
        end

        blob.update_columns(key: new_key, service_name: "amazon")
        migrated += 1
        print "\r  Migrated: #{migrated}/#{total} (failed: #{failed})"
      rescue ActiveStorage::FileNotFoundError
        skipped += 1
        Rails.logger.warn "Blob #{blob.id} (#{blob.filename}): local file missing, skipped"
      rescue => e
        failed += 1
        Rails.logger.error "Blob #{blob.id} (#{blob.filename}): #{e.message}"
      end
    end

    puts "\n\nDone!"
    puts "  Migrated: #{migrated}"
    puts "  Skipped (file missing): #{skipped}"
    puts "  Failed: #{failed}"
    puts "  Total: #{total}"
  end
end
