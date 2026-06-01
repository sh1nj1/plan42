# frozen_string_literal: true

# Provide fallback Active Record encryption keys so encrypted attributes such as
# User#llm_api_key work even when credentials are not populated (e.g. in
# development). Environments that already set the keys via ENV/credentials are
# left untouched.
# Fallback key generation AND read-side options (support_unencrypted_data,
# extend_queries) live in `lib/encryption_bootstrap.rb` so boot-time DB reads
# (storage.yml, environments/*.rb) and this initializer stay in sync. The
# helper is idempotent.
EncryptionBootstrap.ensure_keys!(Rails.application)

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
