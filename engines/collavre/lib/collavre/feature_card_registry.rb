# frozen_string_literal: true

module Collavre
  # Registry for the empty-chat "feature discovery" cards shown when a
  # Creative's comment thread has no comments yet. Mirrors the
  # Collavre::IntegrationRegistry pattern so vendor engines can register
  # their own cards later without touching the core empty-state view.
  #
  # @example Registering a card
  #   Collavre::FeatureCardRegistry.register(:add_user, {
  #     icon: "user-plus",
  #     title_key: "collavre.comments.empty_state.cards.add_user.title",
  #     description_key: "collavre.comments.empty_state.cards.add_user.description",
  #     action: { type: :share_modal },
  #     guide_enabled: false
  #   })
  class FeatureCardRegistry
    include Singleton

    def initialize
      @cards = {}
      @mutex = Mutex.new
    end

    # Register a new feature card
    # @param key [Symbol] Unique identifier for the card
    # @param config [Hash] Configuration options
    # @option config [String] :icon Icon identifier (optional)
    # @option config [String] :title_key i18n key for the card title
    # @option config [String] :description_key i18n key for the card description
    # @option config [Hash] :action Optional { type:, label_key: } describing a call-to-action button
    # @option config [Boolean] :guide_enabled Whether the "learn more" link is active (default false)
    def register(key, config)
      card = FeatureCard.new(key, config)
      @mutex.synchronize do
        @cards[key.to_sym] = card
      end
      card
    end

    def unregister(key)
      @mutex.synchronize do
        @cards.delete(key.to_sym)
      end
    end

    def find(key)
      @mutex.synchronize do
        @cards[key.to_sym]
      end
    end

    def all
      @mutex.synchronize do
        @cards.values
      end
    end

    def each(&block)
      all.each(&block)
    end

    def any?
      @mutex.synchronize do
        @cards.any?
      end
    end

    # Clear all cards (useful for testing)
    def reset!
      @mutex.synchronize do
        @cards = {}
      end
    end

    class << self
      delegate :register, :unregister, :find, :all, :each, :any?, :reset!, to: :instance
    end
  end

  # Represents a registered feature card
  class FeatureCard
    attr_reader :key, :icon, :title_key, :description_key, :action, :guide_enabled

    def initialize(key, config)
      @key = key.to_sym
      @icon = config[:icon]
      @title_key = config[:title_key]
      @description_key = config[:description_key]
      @action = config[:action]
      @guide_enabled = config.fetch(:guide_enabled, false)

      validate!
    end

    def guide_enabled?
      @guide_enabled
    end

    private

    def validate!
      raise ArgumentError, "FeatureCard must have a :title_key" unless @title_key.present?
      raise ArgumentError, "FeatureCard must have a :description_key" unless @description_key.present?
    end
  end
end
