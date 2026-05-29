# frozen_string_literal: true

module Collavre
  module IntegrationSettings
    # Resolves the live value for a registered integration setting key.
    #
    # Precedence: **DB > ENV > registered default.**
    # - DB value wins as long as an `IntegrationSetting` row exists with a
    #   non-blank value (encrypted at rest via `IntegrationSetting`).
    # - ENV is consulted only when no DB row exists.
    # - The registry's static default is the final fallback.
    #
    # Reads are memoized in `Rails.cache` for 5 minutes under
    # `IntegrationSetting.cache_key_for(key)`. The model's `after_commit`
    # hook invalidates this key on any write.
    class Resolver
      # Raised by {.get} when the key has not been registered.
      class UnknownKeyError < StandardError; end

      CACHE_TTL = 5.minutes

      class << self
        # Resolve the current value for a registered key.
        #
        # @param key [Symbol, String]
        # @return [String, nil]
        # @raise [UnknownKeyError] if the key is not registered
        def get(key)
          definition = Registry.instance.find(key) or
            raise UnknownKeyError, "Unknown integration setting: #{key}"

          Rails.cache.fetch(IntegrationSetting.cache_key_for(definition.key), expires_in: CACHE_TTL) do
            db_value(definition) || env_value(definition) || definition.default
          end
        end

        # Report which source currently provides the value for a key.
        #
        # @param key [Symbol, String]
        # @return [Symbol] one of `:db`, `:env`, `:default`, or `:unknown`
        def source_for(key)
          definition = Registry.instance.find(key) or return :unknown
          return :db  if IntegrationSetting.find_by(key: definition.key)&.value.present?
          return :env if ENV[definition.env_var].present?
          :default
        end

        private

        def db_value(definition)
          IntegrationSetting.find_by(key: definition.key)&.value.presence
        end

        def env_value(definition)
          ENV[definition.env_var].presence
        end
      end
    end
  end
end
