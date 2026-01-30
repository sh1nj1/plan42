# frozen_string_literal: true

module Collavre
  # Registry for third-party integrations (Slack, GitHub, Notion, etc.)
  # Allows extensions to register themselves and provide UI components
  # without modifying the core Collavre engine.
  #
  # @example Registering an integration
  #   Collavre::IntegrationRegistry.register(:slack, {
  #     label: "Slack",
  #     icon: "slack",
  #     description: "Sync chat messages with Slack channels",
  #     routes: CollavreSlack::Engine.routes.url_helpers,
  #     creative_menu_partial: "collavre_slack/integrations/creative_menu",
  #     settings_partial: "collavre_slack/integrations/settings"
  #   })
  #
  class IntegrationRegistry
    include Singleton

    def initialize
      @integrations = {}
      @mutex = Mutex.new
    end

    # Register a new integration
    # @param name [Symbol] Unique identifier for the integration
    # @param config [Hash] Configuration options
    # @option config [String] :label Display name
    # @option config [String] :icon Icon identifier (optional)
    # @option config [String] :description Brief description (optional)
    # @option config [Object] :routes Engine routes url_helpers
    # @option config [String] :creative_menu_partial Partial for creative action menu
    # @option config [String] :settings_partial Partial for settings page (optional)
    # @option config [Proc] :enabled_for Lambda to check if enabled for a creative (optional)
    def register(name, config)
      integration = Integration.new(name, config)
      @mutex.synchronize do
        @integrations[name.to_sym] = integration
      end
      Rails.logger.info("[Collavre] Integration registered: #{name}")
      integration
    end

    # Unregister an integration
    def unregister(name)
      @mutex.synchronize do
        @integrations.delete(name.to_sym)
      end
    end

    # Get a specific integration by name
    def find(name)
      @mutex.synchronize do
        @integrations[name.to_sym]
      end
    end

    # Get all registered integrations
    def all
      @mutex.synchronize do
        @integrations.values
      end
    end

    # Iterate over all integrations
    def each(&block)
      all.each(&block)
    end

    # Check if any integrations are registered
    def any?
      @mutex.synchronize do
        @integrations.any?
      end
    end

    # Clear all integrations (useful for testing)
    def reset!
      @mutex.synchronize do
        @integrations = {}
      end
    end

    # Class methods for convenient access
    class << self
      delegate :register, :unregister, :find, :all, :each, :any?, :reset!, to: :instance
    end
  end

  # Represents a registered integration
  class Integration
    attr_reader :name, :label, :icon, :description, :routes,
                :creative_menu_partial, :settings_partial, :enabled_for

    def initialize(name, config)
      @name = name.to_sym
      @label = config[:label] || name.to_s.titleize
      @icon = config[:icon]
      @description = config[:description]
      @routes = config[:routes]
      @creative_menu_partial = config[:creative_menu_partial]
      @settings_partial = config[:settings_partial]
      @enabled_for = config[:enabled_for] || ->(_creative) { true }

      validate!
    end

    # Check if this integration is enabled for a specific creative
    def enabled_for?(creative)
      return true unless @enabled_for.respond_to?(:call)
      @enabled_for.call(creative)
    end

    # Generate a path using the integration's routes
    def path_for(method_name, **args)
      return nil unless @routes
      return nil unless @routes.respond_to?(method_name)
      @routes.public_send(method_name, **args)
    end

    private

    def validate!
      raise ArgumentError, "Integration must have a :label" unless @label.present?
      raise ArgumentError, "Integration must have a :creative_menu_partial" unless @creative_menu_partial.present?
    end
  end
end
