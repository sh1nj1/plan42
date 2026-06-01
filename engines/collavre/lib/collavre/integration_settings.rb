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
        end
      value.presence || default
    end
  end
end
