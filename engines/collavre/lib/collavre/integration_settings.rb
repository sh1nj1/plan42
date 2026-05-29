# frozen_string_literal: true

# Entry point for the Collavre integration settings subsystem.
# Loads the registry value-object, registry singleton, and resolver
# (when present). Loaded from `engines/collavre/lib/collavre.rb` so
# constants are available before any engine `to_prepare` blocks run.

require_relative "integration_settings/key_definition"
require_relative "integration_settings/registry"

module Collavre
  module IntegrationSettings
  end
end
