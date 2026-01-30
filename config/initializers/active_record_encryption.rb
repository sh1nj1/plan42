# frozen_string_literal: true

# Provide fallback Active Record encryption keys so encrypted attributes such as
# User#llm_api_key work even when credentials are not populated (e.g. in
# development). Environments that already set the keys via ENV/credentials are
# left untouched.
encryption_config = Rails.application.config.active_record.encryption

# Allow reading unencrypted data from encrypted columns (for migration period)
encryption_config.support_unencrypted_data = true

# Allow reading data encrypted with previous keys (for key rotation)
encryption_config.extend_queries = true

return if encryption_config.primary_key.present? &&
          encryption_config.deterministic_key.present? &&
          encryption_config.key_derivation_salt.present?

key_generator = ActiveSupport::KeyGenerator.new(
  Rails.application.secret_key_base,
  iterations: 1000
)
key_len = ActiveSupport::MessageEncryptor.key_len

encryption_config.primary_key ||= key_generator.generate_key("active_record_encryption_primary_key", key_len)
encryption_config.deterministic_key ||= key_generator.generate_key("active_record_encryption_deterministic_key", key_len)
encryption_config.key_derivation_salt ||= "active_record_encryption_salt"

# Patch ActiveRecord::Encryption to handle decryption errors gracefully.
#
# Problem: When `secret_key_base` changes, the encryption keys derived from it
# also change. This makes previously encrypted data (e.g., google_refresh_token)
# impossible to decrypt, causing "AEAD authentication tag verification failed".
#
# Rails' default behavior is to raise an exception when decryption fails during
# model loading. Since Rails automatically decrypts ALL encrypted columns when
# loading a model, a single corrupted token causes the entire page to fail with
# a 500 error - even if the page doesn't need that token.
#
# Solution: Catch decryption errors and return nil instead of raising. This
# allows the app to continue functioning, and users can simply re-authenticate
# to get a new valid token stored with the current encryption key.
Rails.application.config.after_initialize do
  ActiveRecord::Encryption::Encryptor.class_eval do
    alias_method :original_decrypt, :decrypt

    def decrypt(encrypted_text, **options)
      original_decrypt(encrypted_text, **options)
    rescue ActiveRecord::Encryption::Errors::Decryption,
           ActiveSupport::MessageEncryptor::InvalidMessage,
           OpenSSL::Cipher::CipherError => e
      Rails.logger.warn("Encryption decryption failed, returning nil: #{e.class} - #{e.message}")
      nil
    end
  end
end
