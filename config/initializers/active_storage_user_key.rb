# frozen_string_literal: true

# Prefix Active Storage blob keys with the current user's ID
# so files are organized under users/{user_id}/ in S3.
#
# Uses Collavre::Current.user (thread-safe via ActiveSupport::CurrentAttributes)
# to determine the uploading user at blob creation time.

Rails.application.config.after_initialize do
  ActiveStorage::Blob.prepend(ActiveStorageUserKeyPrefix)
end

module ActiveStorageUserKeyPrefix
  def key
    # Only set prefix on new records that don't have a key yet
    if new_record? && self[:key].nil?
      token = self.class.generate_unique_secure_token(length: self.class::MINIMUM_TOKEN_LENGTH)
      user_id = Collavre::Current.user&.id

      self[:key] = if user_id.present?
                     "users/#{user_id}/#{token}"
      else
                     "unscoped/#{token}"
      end
    end

    self[:key] || super
  end
end
