# frozen_string_literal: true

module Collavre
  # Stores externally-configurable integration secrets (Slack, Google OAuth,
  # AWS S3/SES, FCM, etc.) on a per-key basis with `value` encrypted at rest.
  #
  # Distinct from {Collavre::SystemSetting}, which stores unencrypted app-behavior
  # toggles (rate limits, themes, etc.). Pair with
  # {Collavre::IntegrationSettings::Registry} (key definitions) and
  # {Collavre::IntegrationSettings::Resolver} (DB > ENV > default precedence).
  class IntegrationSetting < ApplicationRecord
    self.table_name = "integration_settings"

    encrypts :value, deterministic: false

    validates :key, presence: true, uniqueness: true
    validates :category, presence: true

    after_commit :clear_cache

    def self.cache_key_for(key)
      "collavre/integration_setting/#{key}"
    end

    private

    def clear_cache
      Rails.cache.delete(self.class.cache_key_for(key))
      if saved_change_to_key?
        old_key = saved_change_to_key.first
        Rails.cache.delete(self.class.cache_key_for(old_key)) if old_key.present?
      end
    end
  end
end
