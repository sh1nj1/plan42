# frozen_string_literal: true

# Entry point for the Collavre integration settings subsystem.
# Loads the registry value-object, registry singleton, and resolver
# (when present). Loaded from `engines/collavre/lib/collavre.rb` so
# constants are available before any engine `to_prepare` blocks run.

require_relative "integration_settings/key_definition"
require_relative "integration_settings/registry"
require_relative "integration_settings/resolver"

module Collavre
  module IntegrationSettings
    # Resolve a registered key with a safety net for boot-time consumers.
    # Returns `Resolver.get(key)` when the registry+DB are reachable, otherwise
    # falls back to `ENV[key.upcase]`. After the next boot, the DB value wins —
    # matching the `requires_restart` semantics callers register.
    def self.fetch(key, default: nil)
      return ENV[key.to_s.upcase].presence || default unless defined?(Resolver)

      value =
        begin
          Resolver.get(key)
        rescue Resolver::UnknownKeyError
          nil
        rescue ActiveRecord::StatementInvalid,
               ActiveRecord::NoDatabaseError,
               ActiveRecord::ConnectionNotEstablished,
               NameError
          ENV[key.to_s.upcase]
        rescue StandardError => e
          # Encryption may not be configured yet at boot-time: the host app's
          # `config/initializers/active_record_encryption.rb` fallback runs at
          # `:load_config_initializers`, later than `:load_environment_config`
          # where AWS keys are consumed. Treat any encryption-layer error as
          # "DB unavailable" and fall back to ENV.
          raise unless defined?(ActiveRecord::Encryption::Errors::Base) &&
                       e.is_a?(ActiveRecord::Encryption::Errors::Base)
          ENV[key.to_s.upcase]
        end
      value.presence || default
    end
  end
end
