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
  #     guide: true
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
    # @option config [Boolean] :guide Opt in to the engine-provided public guide page at
    #   collavre.feature_path(key). Only set this once the page's copy exists under
    #   collavre.features.pages.<key> — FeaturesController#show 404s for cards without it.
    # @option config [String] :guide_url Optional URL overriding the engine guide page, for
    #   vendor engines that host their own documentation.
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

    # Cards that render on the public /features hub — only those opting into the
    # engine-provided guide page, since a vendor card pointing at its own
    # :guide_url has no page here to link to.
    def with_builtin_guide
      all.select(&:builtin_guide?)
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
      delegate :register, :unregister, :find, :all, :with_builtin_guide, :each, :any?, :reset!, to: :instance
    end
  end

  # Represents a registered feature card
  class FeatureCard
    attr_reader :key, :icon, :title_key, :description_key, :action, :guide_url

    def initialize(key, config)
      @key = key.to_sym
      @icon = config[:icon]
      @title_key = config[:title_key]
      @description_key = config[:description_key]
      @action = config[:action]
      @guide = config.fetch(:guide, false)
      @guide_url = config[:guide_url]

      validate!
    end

    def guide_url?
      @guide_url.present?
    end

    # True when this card is served by the engine's own /features/:key page.
    # A card carrying its own :guide_url is documented elsewhere, so the engine
    # neither renders nor routes a page for it.
    def builtin_guide?
      @guide && !guide_url?
    end

    # True when the empty-state card should render a "learn more" link at all.
    def guide_link?
      builtin_guide? || guide_url?
    end

    private

    def validate!
      raise ArgumentError, "FeatureCard must have a :title_key" unless @title_key.present?
      raise ArgumentError, "FeatureCard must have a :description_key" unless @description_key.present?
    end
  end
end
