# frozen_string_literal: true

# Idempotent fallback Active Record encryption key generator.
#
# Lets boot-time DB readers (`config/storage.yml`, `config/environments/*.rb`)
# decrypt rows BEFORE `config/initializers/active_record_encryption.rb` runs.
# Without this, deployments that rely on the initializer to populate
# encryption keys (no `RAILS_MASTER_KEY` / no explicit encryption ENV) hit
# `ActiveRecord::Encryption::Errors::Configuration` whenever environments
# config reads an encrypted `integration_settings` row, the Phase 3
# `boot_safe:` rescue returns blank, and `:amazon` storage falls back to
# `:local` even though an admin saved valid S3 credentials in the DB.
#
# Mirrors the fallback logic in `config/initializers/active_record_encryption.rb`
# so both callers stay in sync — the initializer's `return if ... present?`
# guard makes this safe to call ahead of it.
#
# Required eagerly from `config/application.rb`.
module EncryptionBootstrap
  module_function

  def ensure_keys!(rails_app = Rails.application)
    return unless defined?(ActiveRecord::Encryption)

    encryption_config = rails_app.config.active_record.encryption
    return if encryption_config.primary_key.present? &&
              encryption_config.deterministic_key.present? &&
              encryption_config.key_derivation_salt.present?

    secret = rails_app.secret_key_base
    return if secret.blank?

    key_generator = ActiveSupport::KeyGenerator.new(secret, iterations: 1000)
    key_len = ActiveSupport::MessageEncryptor.key_len

    encryption_config.primary_key ||=
      key_generator.generate_key("active_record_encryption_primary_key", key_len)
    encryption_config.deterministic_key ||=
      key_generator.generate_key("active_record_encryption_deterministic_key", key_len)
    encryption_config.key_derivation_salt ||= "active_record_encryption_salt"
  end
end
