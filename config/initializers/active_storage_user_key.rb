# frozen_string_literal: true

# Prefix Active Storage blob keys with the current user's ID
# so files are organized under users/{user_id}/ in S3.
#
# Uses Collavre::Current.user (thread-safe via ActiveSupport::CurrentAttributes)
# to determine the uploading user at blob creation time.
#
# For variant blobs (thumbnails/resized images), the user prefix is inherited
# from the original blob's key, since Current.user may not be set during
# background variant processing.

Rails.application.config.after_initialize do
  ActiveStorage::Blob.prepend(ActiveStorageUserKeyPrefix)
  ActiveStorage::Variant.prepend(ActiveStorageVariantUserKey)
end

module ActiveStorageUserKeyPrefix
  def key
    # Only set prefix on new records that don't have a key yet
    if new_record? && self[:key].nil?
      token = self.class.generate_unique_secure_token(length: self.class::MINIMUM_TOKEN_LENGTH)

      # Check for user prefix: Current.user or inherited from variant source blob
      user_prefix = if Collavre::Current.user&.id.present?
                      "users/#{Collavre::Current.user.id}"
      elsif Thread.current[:active_storage_user_prefix].present?
                      Thread.current[:active_storage_user_prefix]
      end

      self[:key] = if user_prefix
                     "#{user_prefix}/#{token}"
      else
                     "unscoped/#{token}"
      end
    end

    self[:key] || super
  end
end

module ActiveStorageVariantUserKey
  # Pass the original blob's user prefix to the variant blob via thread-local
  def process
    source_key = blob.key
    # Extract user prefix (e.g. "users/42") from original blob key
    if source_key&.start_with?("users/")
      # "users/42/abc123..." → "users/42"
      parts = source_key.split("/")
      Thread.current[:active_storage_user_prefix] = "#{parts[0]}/#{parts[1]}"
    end

    super
  ensure
    Thread.current[:active_storage_user_prefix] = nil
  end
end
