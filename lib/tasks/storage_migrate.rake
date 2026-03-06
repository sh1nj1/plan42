# frozen_string_literal: true

# =============================================================================
# storage:migrate_to_s3
# =============================================================================
#
# Rake task to migrate local Active Storage files to AWS S3.
#
# What it does:
#   1. Finds all ActiveStorage::Blob records with service_name "local"
#   2. Determines the owning user for each blob to generate a user-prefixed key
#      - Collavre::Comment → comment.user_id
#      - Collavre::User   → record_id (user's own avatar)
#      - Unknown owner    → "unscoped/" prefix
#   3. Uploads local files to S3 with the new key
#   4. Updates the DB: key → new prefixed key, service_name → "amazon"
#
# S3 folder structure:
#   collavre-uploads-production/
#   ├── users/
#   │   ├── 42/abc123...   (user 42's files)
#   │   └── 87/def456...   (user 87's files)
#   └── unscoped/
#       └── ghi789...      (files with unknown owner)
#
# Prerequisites:
#   - "amazon" service must be defined in config/storage.yml
#   - AWS env vars configured (AWS_S3_ACCESS_KEY_ID, AWS_S3_SECRET_ACCESS_KEY, AWS_S3_BUCKET)
#   - S3 bucket created (see bin/setup_s3.rb)
#
# Usage:
#   # Local development
#   bin/rails storage:migrate_to_s3
#
#   # Kamal production server (maintenance window recommended)
#   ./kamal.sh app exec "bin/rails storage:migrate_to_s3"
#
# Notes:
#   - Run during a maintenance window on production (file I/O + network load)
#   - Blobs with missing local files are skipped (warning logged)
#   - Failed blobs keep service_name "local", so the task can be re-run safely
# =============================================================================

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
      # Determine owner: extract user_id based on attachment record_type
      # For variant blobs (ActiveStorage::VariantRecord), trace back to the
      # original blob's attachment to find the owning user.
      attachment = blob.attachments.first
      user_id = resolve_user_id(attachment)

      # Generate new S3 key with user-prefixed folder
      new_key = if user_id
                  "users/#{user_id}/#{ActiveStorage::Blob.generate_unique_secure_token}"
      else
                  "unscoped/#{ActiveStorage::Blob.generate_unique_secure_token}"
      end

      begin
        # Open local file as tempfile and upload to S3
        blob.open do |tempfile|
          s3_service.upload(new_key, tempfile,
            checksum: blob.checksum,
            content_type: blob.content_type)
        end

        # Update DB: new key + service_name change (direct update, skipping callbacks)
        blob.update_columns(key: new_key, service_name: "amazon")
        migrated += 1
        print "\r  Migrated: #{migrated}/#{total} (failed: #{failed})"
      rescue ActiveStorage::FileNotFoundError
        # Local file already deleted — skip
        skipped += 1
        Rails.logger.warn "Blob #{blob.id} (#{blob.filename}): local file missing, skipped"
      rescue => e
        # Other errors — service_name stays "local" so it can be retried on re-run
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

  # Resolve the owning user_id from an attachment.
  # For variant blobs, traces back through:
  #   VariantRecord → original blob → attachment → user
  def resolve_user_id(attachment)
    return nil unless attachment

    case attachment.record_type
    when "Collavre::Comment"
      attachment.record&.user_id
    when "Collavre::User"
      attachment.record_id
    when "ActiveStorage::VariantRecord"
      # Variant blob: VariantRecord belongs_to :blob (the original)
      variant_record = attachment.record
      return nil unless variant_record

      original_blob = variant_record.blob
      return nil unless original_blob

      # Find the original blob's attachment to determine the user
      original_attachment = original_blob.attachments.first
      resolve_user_id(original_attachment)
    end
  end
end
