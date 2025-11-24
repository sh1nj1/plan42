# frozen_string_literal: true

# Provide fallback Active Record encryption keys so encrypted attributes such as
# User#llm_api_key work even when credentials are not populated (e.g. in
# development). Environments that already set the keys via ENV/credentials are
# left untouched.
encryption_config = Rails.application.config.active_record.encryption

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
