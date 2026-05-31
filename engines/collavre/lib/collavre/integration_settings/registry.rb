# frozen_string_literal: true

require "singleton"

module Collavre
  module IntegrationSettings
    # Singleton registry of integration setting key definitions.
    # Engines register their keys at boot via `to_prepare`, then the
    # admin UI and {Resolver} consult this registry.
    class Registry
      include Singleton

      def initialize
        @definitions = {}
      end

      # Register a key definition.
      #
      # @param key [Symbol, String] canonical identifier (e.g. :slack_client_id)
      # @param category [String] grouping label (e.g. "slack")
      # @param sensitive [Boolean] when true, value is masked in admin UI
      # @param requires_restart [Boolean] when true, surfaces restart-required badge
      # @param env_var [String, nil] ENV variable name (defaults to key.upcase)
      # @param default [String, nil] static fallback used when DB & ENV blank
      # @return [KeyDefinition]
      def register(key, category:, sensitive: true, requires_restart: false, env_var: nil, default: nil)
        key = key.to_sym
        @definitions[key] = KeyDefinition.new(
          key: key,
          category: category,
          sensitive: sensitive,
          requires_restart: requires_restart,
          env_var: env_var || key.to_s.upcase,
          default: default
        )
      end

      # @return [Array<KeyDefinition>] all registered definitions (frozen snapshot)
      def all
        @definitions.values.freeze
      end

      # @param key [Symbol, String]
      # @return [KeyDefinition, nil]
      def find(key)
        @definitions[key.to_sym]
      end

      # @return [Hash{String => Array<KeyDefinition>}] definitions grouped by category
      def by_category
        @definitions.values.group_by(&:category)
      end
    end
  end
end
